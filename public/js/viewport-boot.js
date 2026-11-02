// The Duo outer display's Safari web view extends under its status column.
// Apply the tested explicit viewport BEFORE styles or layout reads (probe B).
// Keep this a synchronous, self-hosted script: the app's CSP disallows inline JS.
// Only portrait is enabled; landscape needs separate left-column alignment.
;(function () {
  var root = document.documentElement
  var viewport = document.querySelector('meta[name="viewport"]')
  if (!viewport) return
  var original = viewport.content
  var wide = 'width=466, height=device-height, initial-scale=1, minimum-scale=1, viewport-fit=cover'
  var ua = navigator.userAgent || ''
  var ios = /iPhone|iPad|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
  var standalone = navigator.standalone === true || matchMedia('(display-mode: standalone)').matches
  var safari = /AppleWebKit/.test(ua) && /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|OPiOS|MicroMessenger|GSA\//.test(ua)
  var disabled = new URLSearchParams(location.search).get('wide') === 'off'

  function target() {
    if (disabled || !ios || (!safari && !standalone) || !matchMedia('(pointer: coarse)').matches) return false
    var short = Math.min(screen.width, screen.height)
    var long = Math.max(screen.width, screen.height)
    // Screen geometry, not the layout width we are about to change. Opening
    // the inner display must restore device-width so the app can split again.
    if (Math.abs(short - 466) > 2 || Math.abs(long - 678) > 2) return false
    var type = screen.orientation && screen.orientation.type
    if (type ? type.indexOf('portrait') !== 0 : typeof window.orientation === 'number'
      ? Math.abs(window.orientation) === 90 : screen.width > screen.height) return false
    // A genuinely narrow window is not the 84–90pt Safari status column.
    // outerWidth is window geometry; don't force a narrow document layout to
    // measure innerWidth/clientWidth before the early viewport is applied.
    if (window.outerWidth > 0 && window.outerWidth < 326) return false
    return true
  }

  function refresh(early) {
    var on = target()
    var vv = window.visualViewport
    if (on && early !== true && vv) {
      // Pinch zoom changes vv.width too. Multiplying by scale avoids mistaking
      // it for split view; a normal expanded view may still report ~382px.
      var visible = vv.width * vv.scale
      if (visible > 0 && visible < 326) on = false
    }
    var content = on ? wide : original
    if (viewport.content !== content) viewport.content = content
    if (on) {
      root.dataset.wide = 'outer'
      var inset = 90
      if (early !== true && vv) {
        var gap = 466 - vv.width * vv.scale
        if (gap >= 48 && gap <= 140) inset = Math.ceil(gap)
      }
      // Backgrounds use the full viewport; the existing UI safe-area rules
      // keep text, Send, calls, sheets and menus out from under the controls.
      root.style.setProperty('--wide-inset-right', inset + 'px')
    } else {
      delete root.dataset.wide
      root.style.removeProperty('--wide-inset-right')
    }
  }

  refresh(true)
  document.addEventListener('DOMContentLoaded', refresh)
  window.addEventListener('resize', refresh)
  window.addEventListener('orientationchange', refresh)
  screen.orientation && screen.orientation.addEventListener && screen.orientation.addEventListener('change', refresh)
  window.addEventListener('pageshow', refresh)
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) refresh()
  })
})()
