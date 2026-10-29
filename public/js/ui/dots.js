// The image sheet's dot field, drawn with WebGPU where the browser has it
// (Safari 26 and later): every dot of a frame is one instance of a single
// draw, its disc cut and antialiased in the fragment shader, instead of a
// path and a fill per dot on the main thread. Without WebGPU, or if the GPU device is lost, the same
// dots go through Canvas 2D.
//
// Both renderers take a frame as begin(width, height, scale, color), then
// dot(x, y, radius, alpha) for each dot in units of width × height, then
// end(); `scale` is device pixels per unit.

const SHADER = /* wgsl */ `
struct View { size: vec2f, px: f32, pad: f32, color: vec4f }
@group(0) @binding(0) var<uniform> view: View;

struct Varying {
  @builtin(position) position: vec4f,
  @location(0) local: vec2f,
  @location(1) radius: f32,
  @location(2) alpha: f32,
}

@vertex fn vs(@builtin(vertex_index) v: u32, @location(0) dot: vec4f) -> Varying {
  let corners = array<vec2f, 6>(vec2f(-1, -1), vec2f(1, -1), vec2f(-1, 1), vec2f(-1, 1), vec2f(1, -1), vec2f(1, 1));
  // One device pixel of room around the disc for its antialiased edge.
  let reach = dot.z + 1.0 / view.px;
  let p = dot.xy + corners[v] * reach;
  var out: Varying;
  out.position = vec4f(p.x / view.size.x * 2.0 - 1.0, 1.0 - p.y / view.size.y * 2.0, 0.0, 1.0);
  out.local = corners[v] * reach;
  out.radius = dot.z;
  out.alpha = dot.w;
  return out;
}

@fragment fn fs(in: Varying) -> @location(0) vec4f {
  let cover = clamp((in.radius - length(in.local)) * view.px + 0.5, 0.0, 1.0);
  let a = view.color.a * in.alpha * cover;
  return vec4f(view.color.rgb * a, a);
}`

/** Canvas 2D: one path and fill per dot. */
export function canvasDots(canvas) {
  const g = canvas.getContext('2d')
  if (!g) return null
  return {
    kind: '2d',
    canvas,
    begin(width, height, scale, color) {
      g.setTransform(scale, 0, 0, scale, 0, 0)
      g.clearRect(0, 0, width, height)
      g.fillStyle = color
    },
    dot(x, y, r, alpha) {
      g.globalAlpha = alpha
      g.beginPath()
      g.arc(x, y, r, 0, Math.PI * 2)
      g.fill()
    },
    end() { g.globalAlpha = 1 },
    destroy() {}
  }
}

// One device for every field; dropped (and asked for again) if it's lost.
let device = null
const pipelines = new Map()
function gpuDevice() {
  device ??= (async () => {
    const adapter = await navigator.gpu?.requestAdapter({ powerPreference: 'low-power' })
    const d = await adapter?.requestDevice()
    if (!d) return null
    d.lost.then(() => {
      device = null
      pipelines.clear()
    })
    return d
  })().catch(() => null)
  return device
}

// Compiled off the main thread, once per canvas format.
function pipelineFor(d, format) {
  if (!pipelines.has(format)) {
    const module = d.createShaderModule({ code: SHADER })
    const blend = { srcFactor: 'one', dstFactor: 'one-minus-src-alpha', operation: 'add' }
    pipelines.set(format, d.createRenderPipelineAsync({
      layout: 'auto',
      vertex: { module, entryPoint: 'vs', buffers: [{ arrayStride: 16, stepMode: 'instance', attributes: [{ shaderLocation: 0, offset: 0, format: 'float32x4' }] }] },
      fragment: { module, entryPoint: 'fs', targets: [{ format, blend: { color: blend, alpha: blend } }] },
      primitive: { topology: 'triangle-list' }
    }))
  }
  return pipelines.get(format)
}

const colors = new Map()
/** A CSS color as premultiplication-ready [r, g, b, a] in 0…1. */
function rgba(css) {
  if (!colors.has(css)) {
    const g = document.createElement('canvas').getContext('2d', { willReadFrequently: true })
    g.fillStyle = css
    g.fillRect(0, 0, 1, 1)
    colors.set(css, [...g.getImageData(0, 0, 1, 1).data].map(v => v / 255))
  }
  return colors.get(css)
}

/**
 * WebGPU: resolves to a renderer drawing into its own new canvas, or null
 * where WebGPU isn't available. `onLost` runs if the device goes away.
 */
export async function gpuDots({ onLost } = {}) {
  const d = await gpuDevice()
  if (!d) return null
  try {
    const canvas = document.createElement('canvas')
    const context = canvas.getContext('webgpu')
    if (!context) return null
    const format = navigator.gpu.getPreferredCanvasFormat()
    context.configure({ device: d, format, alphaMode: 'premultiplied' })
    const pipeline = await pipelineFor(d, format)
    const uniform = d.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST })
    const bindGroup = d.createBindGroup({ layout: pipeline.getBindGroupLayout(0), entries: [{ binding: 0, resource: { buffer: uniform } }] })
    const view = new Float32Array(8)
    let data = new Float32Array(4 * 1024)
    let instances = null
    let count = 0
    let destroyed = false
    d.lost.then(() => { if (!destroyed) onLost?.() })
    return {
      kind: 'webgpu',
      canvas,
      begin(width, height, scale, color) {
        count = 0
        view.set([width, height, scale, 0, ...rgba(color)])
      },
      dot(x, y, r, alpha) {
        if (count * 4 === data.length) {
          const grown = new Float32Array(data.length * 2)
          grown.set(data)
          data = grown
        }
        const i = count++ * 4
        data[i] = x
        data[i + 1] = y
        data[i + 2] = r
        data[i + 3] = alpha
      },
      end() {
        if (destroyed || !canvas.width || !canvas.height) return
        if (!instances || instances.size < data.byteLength) {
          instances?.destroy()
          instances = d.createBuffer({ size: data.byteLength, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST })
        }
        d.queue.writeBuffer(uniform, 0, view)
        if (count) d.queue.writeBuffer(instances, 0, data, 0, count * 4)
        const encoder = d.createCommandEncoder()
        const pass = encoder.beginRenderPass({
          colorAttachments: [{ view: context.getCurrentTexture().createView(), loadOp: 'clear', storeOp: 'store', clearValue: { r: 0, g: 0, b: 0, a: 0 } }]
        })
        if (count) {
          pass.setPipeline(pipeline)
          pass.setBindGroup(0, bindGroup)
          pass.setVertexBuffer(0, instances)
          pass.draw(6, count)
        }
        pass.end()
        d.queue.submit([encoder.finish()])
      },
      destroy() {
        destroyed = true
        instances?.destroy()
        uniform.destroy()
        context.unconfigure()
      }
    }
  } catch {
    return null
  }
}

/**
 * Draws with Canvas 2D into `canvas` at once, then moves to WebGPU when it
 * is ready (swapping in its canvas) and back if the device is lost.
 * `use(renderer)` is called on every switch; it should resize and redraw.
 */
export function dotRenderer(canvas, use) {
  let current = canvasDots(canvas)
  let gone = false
  const upgrade = () => gpuDots({ onLost: fallBack }).then(gpu => {
    if (!gpu) return
    if (gone || !current?.canvas.parentNode) { gpu.destroy(); return }
    gpu.canvas.className = current.canvas.className
    gpu.canvas.setAttribute('aria-hidden', 'true')
    current.canvas.replaceWith(gpu.canvas)
    current = gpu
    use(current)
  })
  function fallBack() {
    if (gone || current?.kind !== 'webgpu') return
    const plain = canvasDots(document.createElement('canvas'))
    if (!plain) return
    plain.canvas.className = current.canvas.className
    plain.canvas.setAttribute('aria-hidden', 'true')
    current.canvas.replaceWith(plain.canvas)
    current = plain
    use(current)
  }
  // Only once the field is on screen: the GPU starts when it's needed.
  const seen = new IntersectionObserver(entries => {
    if (!entries.some(e => e.isIntersecting)) return
    seen.disconnect()
    upgrade()
  })
  seen.observe(canvas)
  return {
    get current() { return current },
    destroy() {
      gone = true
      seen.disconnect()
      current?.destroy()
    }
  }
}
