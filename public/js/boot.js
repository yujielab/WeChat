// Runs before first paint so saved appearance settings never flash.
(function () {
  var root = document.documentElement
  function read(key) {
    try {
      return localStorage.getItem(key)
    } catch (e) {
      return null
    }
  }
  // Light (white) unless the user picked System or Dark in Settings.
  var theme = read('ui:theme') || 'light'
  if (theme === 'light' || theme === 'dark') root.setAttribute('data-theme', theme)
  var glass = read('ui:glass') || read('ui:glass-auto')
  // Devices that can't afford live blur start solid, so nothing swaps later.
  var nav = navigator
  var lowEnd = (nav.connection && nav.connection.saveData) || (nav.deviceMemory && nav.deviceMemory <= 2) ||
    (nav.hardwareConcurrency && nav.hardwareConcurrency <= 2)
  if (glass === 'solid' || (lowEnd && !read('ui:glass'))) root.setAttribute('data-glass', 'solid')
  if (read('ui:glass-tint') === 'clear') root.setAttribute('data-glass-tint', 'clear')
  // The light behind the message field (Settings › Composer glow): on, as Ocean, unless turned off.
  var glow = read('ui:glow') || 'ocean'
  if (glow !== 'off') root.setAttribute('data-glow', glow)
  var motion = read('ui:motion')
  if (motion === 'reduce' || motion === 'full') root.setAttribute('data-motion', motion)
})()
