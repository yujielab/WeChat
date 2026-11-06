// A small WebGL2 multi-pass renderer, ported to framework-free JS from
// liquid-glass-studio's src/utils/GLUtils.ts (MIT, (c) 2024 Charles Yin) so the
// Liquid Glass shader can run under this app's CSP with no build step and no
// React. Structure and names follow the original: a ShaderProgram that
// auto-detects uniforms, a FrameBuffer (RGBA16F) per off-screen pass, a
// RenderPass that draws a full-screen quad, and a MultiPassRenderer that wires
// each pass's output texture into the next pass's inputs.

/** Normalised Gaussian weights for a separable blur of the given radius. */
export function gaussianKernel(radius) {
  const sigma = Math.max(0.0001, radius / 3)
  const kernel = []
  let sum = 0
  for (let i = 0; i <= radius; i++) {
    const w = Math.exp((-0.5 * (i * i)) / (sigma * sigma))
    kernel.push(w)
    sum += i === 0 ? w : w * 2
  }
  return kernel.map(w => w / sum)
}

class ShaderProgram {
  constructor(gl, source) {
    this.gl = gl
    this.uniforms = new Map()
    this.attributes = new Map()
    this.program = this._createProgram(source)
    this._detectAttributes()
    this._detectUniforms()
  }
  _createShader(type, src) {
    const gl = this.gl
    const shader = gl.createShader(type)
    gl.shaderSource(shader, src)
    gl.compileShader(shader)
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      const info = gl.getShaderInfoLog(shader)
      gl.deleteShader(shader)
      throw new Error(`shader compile: ${info}`)
    }
    return shader
  }
  _createProgram(source) {
    const gl = this.gl
    const program = gl.createProgram()
    const vs = this._createShader(gl.VERTEX_SHADER, source.vertex)
    const fs = this._createShader(gl.FRAGMENT_SHADER, source.fragment)
    gl.attachShader(program, vs)
    gl.attachShader(program, fs)
    gl.linkProgram(program)
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      const info = gl.getProgramInfoLog(program)
      gl.deleteProgram(program)
      throw new Error(`program link: ${info}`)
    }
    gl.deleteShader(vs)
    gl.deleteShader(fs)
    return program
  }
  _detectAttributes() {
    const gl = this.gl
    const n = gl.getProgramParameter(this.program, gl.ACTIVE_ATTRIBUTES)
    for (let i = 0; i < n; i++) {
      const info = gl.getActiveAttrib(this.program, i)
      if (!info) continue
      this.attributes.set(info.name, { location: gl.getAttribLocation(this.program, info.name) })
    }
  }
  _detectUniforms() {
    const gl = this.gl
    const n = gl.getProgramParameter(this.program, gl.ACTIVE_UNIFORMS)
    const arrayRe = /\[\d+\]$/
    for (let i = 0; i < n; i++) {
      const info = gl.getActiveUniform(this.program, i)
      if (!info) continue
      const location = gl.getUniformLocation(this.program, info.name)
      if (!location) continue
      const name = info.name.replace(arrayRe, '')
      this.uniforms.set(name, { location, type: info.type, isArray: arrayRe.test(info.name) })
    }
  }
  use() { this.gl.useProgram(this.program) }
  attribLocation(name) { return this.attributes.get(name)?.location ?? -1 }
  setUniform(name, value) {
    const gl = this.gl
    const u = this.uniforms.get(name)
    if (!u) return
    const loc = u.location
    if (u.isArray && Array.isArray(value)) {
      switch (u.type) {
        case gl.FLOAT: gl.uniform1fv(loc, value); break
        case gl.FLOAT_VEC2: gl.uniform2fv(loc, value); break
        case gl.FLOAT_VEC3: gl.uniform3fv(loc, value); break
        case gl.FLOAT_VEC4: gl.uniform4fv(loc, value); break
      }
      return
    }
    switch (u.type) {
      case gl.FLOAT: gl.uniform1f(loc, value); break
      case gl.FLOAT_VEC2: gl.uniform2fv(loc, value); break
      case gl.FLOAT_VEC3: gl.uniform3fv(loc, value); break
      case gl.FLOAT_VEC4: gl.uniform4fv(loc, value); break
      case gl.INT: case gl.SAMPLER_2D: gl.uniform1i(loc, value); break
    }
  }
  dispose() {
    const gl = this.gl
    if (this.program) {
      for (const s of gl.getAttachedShaders(this.program) || []) gl.deleteShader(s)
      gl.deleteProgram(this.program)
    }
    this.uniforms.clear()
    this.attributes.clear()
  }
}

class FrameBuffer {
  constructor(gl, width, height) {
    this.gl = gl
    this.width = width
    this.height = height
    this.fbo = gl.createFramebuffer()
    this.texture = gl.createTexture()
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.fbo)
    this._allocColor()
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.texture, 0)
    const status = gl.checkFramebufferStatus(gl.FRAMEBUFFER)
    gl.bindFramebuffer(gl.FRAMEBUFFER, null)
    gl.bindTexture(gl.TEXTURE_2D, null)
    if (status !== gl.FRAMEBUFFER_COMPLETE) throw new Error(`framebuffer incomplete: ${status}`)
  }
  _allocColor() {
    const gl = this.gl
    gl.bindTexture(gl.TEXTURE_2D, this.texture)
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, this.width, this.height, 0, gl.RGBA, gl.FLOAT, null)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
  }
  bind() { this.gl.bindFramebuffer(this.gl.FRAMEBUFFER, this.fbo) }
  unbind() { this.gl.bindFramebuffer(this.gl.FRAMEBUFFER, null) }
  getTexture() { return this.texture }
  resize(width, height) {
    this.width = width
    this.height = height
    this._allocColor()
    this.gl.bindTexture(this.gl.TEXTURE_2D, null)
  }
  dispose() {
    this.gl.deleteFramebuffer(this.fbo)
    this.gl.deleteTexture(this.texture)
  }
}

class RenderPass {
  constructor(gl, config) {
    this.gl = gl
    this.config = config
    this.program = new ShaderProgram(gl, config.shader)
    this.frameBuffer = config.outputToScreen ? null : new FrameBuffer(gl, gl.canvas.width, gl.canvas.height)
    this.vao = this._createVAO()
  }
  _createVAO() {
    const gl = this.gl
    const vao = gl.createVertexArray()
    gl.bindVertexArray(vao)
    const buffer = gl.createBuffer()
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW)
    const loc = this.program.attribLocation('a_position')
    gl.enableVertexAttribArray(loc)
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0)
    gl.bindVertexArray(null)
    gl.bindBuffer(gl.ARRAY_BUFFER, null)
    this.buffer = buffer
    return vao
  }
  render(uniforms) {
    const gl = this.gl
    if (this.frameBuffer) this.frameBuffer.bind()
    else gl.bindFramebuffer(gl.FRAMEBUFFER, null)
    this.program.use()
    if (uniforms) {
      let unit = 0
      for (const [name, value] of Object.entries(uniforms)) {
        if (value instanceof WebGLTexture) {
          gl.activeTexture(gl.TEXTURE0 + unit)
          gl.bindTexture(gl.TEXTURE_2D, value)
          this.program.setUniform(name, unit)
          unit++
        } else if (value !== undefined && value !== null) {
          this.program.setUniform(name, value)
        }
      }
    }
    gl.bindVertexArray(this.vao)
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
    gl.bindVertexArray(null)
    if (this.frameBuffer) this.frameBuffer.unbind()
  }
  getOutputTexture() { return this.frameBuffer ? this.frameBuffer.getTexture() : null }
  resize(w, h) { this.frameBuffer?.resize(w, h) }
  dispose() {
    this.frameBuffer?.dispose()
    this.program.dispose()
    this.gl.deleteBuffer(this.buffer)
    this.gl.deleteVertexArray(this.vao)
  }
}

export class MultiPassRenderer {
  /** configs: [{ name, shader:{vertex,fragment}, inputs?:{uniform:fromPass}, outputToScreen? }] */
  constructor(canvas, configs) {
    const gl = canvas.getContext('webgl2', { premultipliedAlpha: true, alpha: true, antialias: false })
    if (!gl) throw new Error('WebGL2 not supported')
    if (!gl.getExtension('EXT_color_buffer_float')) throw new Error('EXT_color_buffer_float not supported')
    this.gl = gl
    this.passes = new Map()
    this.order = []
    this.globalUniforms = {}
    for (const cfg of configs) {
      const pass = new RenderPass(gl, cfg)
      this.passes.set(cfg.name, pass)
      this.order.push(pass)
    }
  }
  resize(width, height) {
    this.gl.canvas.width = width
    this.gl.canvas.height = height
    for (const p of this.order) p.resize(width, height)
    this.gl.viewport(0, 0, width, height)
  }
  setUniforms(u) { Object.assign(this.globalUniforms, u) }
  render(passUniforms) {
    const gl = this.gl
    gl.viewport(0, 0, gl.canvas.width, gl.canvas.height)
    for (const pass of this.order) {
      const uniforms = { ...this.globalUniforms, ...(passUniforms?.[pass.config.name] || null) }
      if (pass.config.inputs) {
        for (const [uniformName, fromPass] of Object.entries(pass.config.inputs)) {
          uniforms[uniformName] = this.passes.get(fromPass)?.getOutputTexture()
        }
      }
      pass.render(uniforms)
    }
  }
  dispose() {
    for (const p of this.order) p.dispose()
    this.passes.clear()
    this.order = []
    const gl = this.gl
    gl.bindFramebuffer(gl.FRAMEBUFFER, null)
    gl.bindTexture(gl.TEXTURE_2D, null)
  }
}

/** Upload an image/canvas as a texture; returns { texture, ratio }. */
export function textureFromSource(gl, source, width, height) {
  const texture = gl.createTexture()
  gl.bindTexture(gl.TEXTURE_2D, texture)
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true)
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source)
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
  gl.bindTexture(gl.TEXTURE_2D, null)
  const w = width || source.naturalWidth || source.width || 1
  const h = height || source.naturalHeight || source.height || 1
  return { texture, ratio: w / h }
}

/** Replace the pixels of an existing texture from a source (same params). */
export function updateTexture(gl, texture, source) {
  gl.bindTexture(gl.TEXTURE_2D, texture)
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true)
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source)
  gl.bindTexture(gl.TEXTURE_2D, null)
}
