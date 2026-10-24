import { message } from './message.js'

const show = (text) => { document.querySelector('#message').textContent = text }
show(message)
if (import.meta.hot) import.meta.hot.accept('./message.js', (m) => show(m.message))
