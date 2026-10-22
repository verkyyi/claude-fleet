// Test-only worker transport mount. Product task routes never mount a terminal.
// Exercise the actual component and controller through real hub/node/tmux;
// the personal Shell remains covered through its committed production route.
import { createRoot } from 'react-dom/client'
import { BrowserRouter, Routes, Route, useParams } from 'react-router'
import { TerminalView } from '../web-console/src/app/pages/terminal'

function Worker() {
  const { worker = '' } = useParams()
  return <TerminalView worker={worker} />
}
createRoot(document.getElementById('root')!).render(
  <BrowserRouter basename="/app"><Routes>
    <Route path="/__terminal-transport/:worker" element={<Worker />} />
    <Route path="/s/shell" element={<TerminalView worker={null} />} />
  </Routes></BrowserRouter>,
)
