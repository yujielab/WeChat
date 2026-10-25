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
  var theme = read('ui:theme')
  if (theme === 'light' || theme === 'dark') root.setAttribute('data-theme', theme)
  var glass = read('ui:glass') || read('ui:glass-auto')
  if (glass === 'solid') root.setAttribute('data-glass', 'solid')
  var motion = read('ui:motion')
  if (motion === 'reduce' || motion === 'full') root.setAttribute('data-motion', motion)
})()
