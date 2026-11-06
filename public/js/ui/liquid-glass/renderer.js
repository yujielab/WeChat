// WebGL2 helpers for the Liquid Glass, ported to framework-free JS from
// liquid-glass-studio's src/utils/GLUtils.ts (MIT, (c) 2024 Charles Yin) so the
// shader can run under this app's CSP with no build step and no React: a
// ShaderProgram that auto-detects its uniforms, a full-screen quad, and
// texture upload. At the project's default blur radius (1) its blur passes are
// an identity (2% of a texel), so the glass is a single pass over the backdrop
// texture and needs no float framebuffers.

export class ShaderProgram {
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
      if (info) this.attributes.set(info.name, gl.getAttribLocation(this.program, info.name))
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
      this.uniforms.set(info.name.replace(arrayRe, ''), { location, type: info.type, isArray: arrayRe.test(info.name) })
    }
  }
  use() { this.gl.useProgram(this.program) }
  attribLocation(name) { return this.attributes.get(name) ?? -1 }
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
}

/** A full-screen quad for `program`'s a_position. */
export function quad(gl, program) {
  const vao = gl.createVertexArray()
  gl.bindVertexArray(vao)
  const buffer = gl.createBuffer()
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW)
  const loc = program.attribLocation('a_position')
  gl.enableVertexAttribArray(loc)
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0)
  gl.bindVertexArray(null)
  gl.bindBuffer(gl.ARRAY_BUFFER, null)
  return vao
}

/** Upload an image/canvas into `texture` (created when null); returns it. */
export function uploadTexture(gl, texture, source) {
  if (!texture) {
    texture = gl.createTexture()
    gl.bindTexture(gl.TEXTURE_2D, texture)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
  } else {
    gl.bindTexture(gl.TEXTURE_2D, texture)
  }
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true)
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, source)
  gl.bindTexture(gl.TEXTURE_2D, null)
  return texture
}
