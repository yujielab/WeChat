// Clarinetta is the app's face everywhere, iPhone included: the Dynamic Type shorthand there sets the family
// too, so it must be set again after it. Every face points at a file that exists, and no two different files
// are the same font (Clarinetta-RegularItalic.woff2 shipped as a copy of the Black Italic).
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'

const css = f => readFileSync(new URL(`../public/css/${f}`, import.meta.url), 'utf8')

test('the text face is Clarinetta, and stays so under iOS Dynamic Type', () => {
  assert.match(css('tokens.css'), /--font-text:\s*"Clarinetta"/)
  const base = css('base.css')
  assert.match(base, /html\s*\{[^}]*font-family:\s*var\(--font-text\)/)
  const block = base.match(/@supports \(font: -apple-system-body\)\s*\{([\s\S]*?)\n\}/)
  assert.ok(block, 'the Dynamic Type rule')
  const rule = block[1]
  assert.ok(rule.indexOf('font: -apple-system-body') < rule.indexOf('font-family: var(--font-text)'), 'the family is set again after the shorthand: ' + rule)
})

test('every face points at a file that exists, and no two files are the same font', () => {
  const files = [...css('fonts.css').matchAll(/url\("\/fonts\/([^"]+)"\)/g)].map(m => m[1])
  assert.ok(files.length >= 12)
  const byHash = new Map()
  for (const f of new Set(files)) {
    const path = new URL(`../public/fonts/${f}`, import.meta.url)
    assert.ok(existsSync(path), f)
    const h = createHash('sha256').update(readFileSync(path)).digest('hex')
    assert.ok(!byHash.has(h), `${f} is the same file as ${byHash.get(h)}`)
    byHash.set(h, f)
  }
})
