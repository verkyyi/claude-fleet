# When the view breaks

When the view (the screen `fleet` opens) breaks, your sessions are not affected — they keep running on your home machine. All you need is somewhere to type a command. From the top down:

## 1. The view still opens: ⌃\

Press `⌃\` in the view to open a command line without leaving it.

## 2. The view keeps failing: you land at a command line

- `fleet` on your computer: when the home machine answers but the view fails to come up 3 times in a row (or quits within a minute of coming up), it stops reconnecting and puts you at the home machine's command line, with one line saying why; type `exit` there to go back to the view.
- A phone / ssh app on the entry port: when the view quits unexpectedly you stay at the home machine's command line instead of being disconnected; type `fleet` to go back.

## 3. The view will not open at all: `fleet shell`

On your Mac (or any computer with `fleet`):

```sh
fleet shell            # your home machine's command line ($HOME), no view
fleet shell mac-a      # another machine, by name
fleet shell --print    # just print the equivalent ssh command, for an ssh app on a phone / iPad
fleet shell --list     # your machines: number · machine · login · online · last heard · which is home
fleet shell 2          # the second one on that list
```

- It uses the view's own connection certificate and route: no new port, no standing key.
- When the hub cannot be reached it uses the route this computer remembered last; with the certificate expired it only takes that machine's entry port (with this computer's own key). A machine without one is said plainly ("cannot get in while the hub is down"), never guessed at.
- Type `fleet` there to go back to the view.
- It only opens a command line: no session is created, no record is changed.

Still stuck? See [Troubleshooting](troubleshooting.md).
