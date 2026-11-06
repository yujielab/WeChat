// One WebGL2 context for all the Liquid Glass on the page (a page gets only a
// handful of contexts): it renders the shader for one button at a time and
// copies the result into that button's own 2D canvas, so the glass sits in
// the button's layer wherever it is (a bar, a sheet, a photo, a call).

import { ShaderProgram, quad, uploadTexture } from './renderer.js'
import * as S from './shaders.js'

let engine = null // { gl, canvas, program, vao, lost, listeners }

function build(e) {
  const gl = e.gl
  e.program = new ShaderProgram(gl, { vertex: S.VERTEX, fragment: S.MAIN })
  e.vao = quad(gl, e.program)
}

/** The shared engine, or null where WebGL2 isn't there (or was lost). */
export function glassEngine() {
  if (engine) return engine.lost ? null : engine
  try {
    const canvas = document.createElement('canvas')
    canvas.width = canvas.height = 128
    const gl = canvas.getContext('webgl2', { premultipliedAlpha: true, alpha: true, antialias: false, preserveDrawingBuffer: true })
    if (!gl) { engine = { lost: true, listeners: new Set() }; return null }
    engine = { gl, canvas, lost: false, listeners: new Set() }
    build(engine)
    canvas.addEventListener('webglcontextlost', ev => {
      ev.preventDefault()
      engine.lost = true
      for (const fn of engine.listeners) fn(false)
    })
    canvas.addEventListener('webglcontextrestored', () => {
      try { build(engine); engine.lost = false } catch { return }
      for (const fn of engine.listeners) fn(true)
    })
    return engine
  } catch {
    engine = { lost: true, listeners: new Set() }
    return null
  }
}

/** Follow the context being lost (false) and restored (true). */
export function onEngine(fn) {
  glassEngine()
  engine.listeners.add(fn)
  return () => engine.listeners.delete(fn)
}

export function uploadBackdrop(e, texture, source) {
  return uploadTexture(e.gl, texture, source)
}
export function dropTexture(e, texture) {
  if (texture && e && !e.lost) e.gl.deleteTexture(texture)
}

/**
 * Draw one button's glass. `job`:
 *   tex, texW, texH   its backdrop texture (phys px), reaching `pad` past the output
 *   outW, outH        the output (phys px)
 *   shape             [cx, cy, halfW, halfH] (phys px, y up) and radius
 *   uniforms          the glass look (u_tint, u_glareAngle, …), u_dpr, u_viewH
 *   target            the button's 2D context, outW × outH
 */
export function renderGlass(e, job) {
  const { gl, canvas, program, vao } = e
  const { outW, outH } = job
  if (canvas.width < outW || canvas.height < outH) {
    canvas.width = Math.max(canvas.width, Math.ceil(outW))
    canvas.height = Math.max(canvas.height, Math.ceil(outH))
  }
  gl.viewport(0, 0, outW, outH)
  program.use()
  gl.activeTexture(gl.TEXTURE0)
  gl.bindTexture(gl.TEXTURE_2D, job.tex)
  program.setUniform('u_bg', 0)
  program.setUniform('u_blurredBg', 0)
  program.setUniform('u_resolution', [job.texW, job.texH])
  program.setUniform('u_texPad', [job.pad, job.pad])
  program.setUniform('u_shapeCount', 1)
  program.setUniform('u_shapeBox', job.shape)
  program.setUniform('u_shapeR', [job.radius])
  for (const [name, value] of Object.entries(job.uniforms)) program.setUniform(name, value)
  gl.bindVertexArray(vao)
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
  gl.bindVertexArray(null)
  gl.bindTexture(gl.TEXTURE_2D, null)
  const t = job.target
  t.clearRect(0, 0, outW, outH)
  t.drawImage(canvas, 0, canvas.height - outH, outW, outH, 0, 0, outW, outH)
}
