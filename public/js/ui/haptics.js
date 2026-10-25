// Light haptic ticks on iPhone. Safari has no Vibration API, but toggling an
// <input type="checkbox" switch> (iOS 18+) plays the system switch haptic.
// Only fires inside a user gesture; elsewhere it is a silent no-op.

import { storage } from './dom.js'

let label = null
const isIOS = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)

function ensure() {
  if (label || !isIOS) return
  label = document.createElement('label')
  label.setAttribute('aria-hidden', 'true')
  label.style.cssText = 'position:fixed;left:-100px;top:0;width:1px;height:1px;overflow:hidden;opacity:0;pointer-events:none'
  const input = document.createElement('input')
  input.type = 'checkbox'
  input.setAttribute('switch', '')
  input.tabIndex = -1
  label.append(input)
  document.body.append(label)
}

export function hapticsEnabled() {
  return storage('ui:haptics') !== 'off'
}

export function haptic() {
  if (!isIOS || !hapticsEnabled()) return
  ensure()
  label?.click()
}
