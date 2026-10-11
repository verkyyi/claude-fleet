import { Shell } from '../app-shell.js';
import { renderSubscriptions, disposeSubscriptions } from './subscriptions.js';
export default Shell.mount('subscription', renderSubscriptions, { dispose: disposeSubscriptions });
