import { getJSON, sendJSON } from '@/shared/api';
import { sessionWrite } from '@/shared/sessions';
import { tr } from '@/shared/i18n';
import type { Row } from './work';
import { requestRowStop, type StopIO, type StopResult } from './task-stop';

const io: StopIO = {
  read: getJSON,
  post: (url, body) => sendJSON('POST', url, body),
  legacy: (worker) => sessionWrite('worker_stop', worker),
};
export const stopRow = (row: Row) => requestRowStop(row, io);
export const stopAcknowledgment = (result: StopResult) => result.exitConfirmed
  ? tr('停止请求已保存；原生会话退出已确认。', 'Stop recorded; native session exit confirmed.')
  : result.legacy
    ? tr('停止请求已提交。', 'Stop requested.')
  : result.neverStarted
    ? tr('停止请求已保存；已确认原会话尚未启动。', 'Stop recorded; the original session never started.')
    : tr('停止请求已提交，等待原生会话退出确认。', 'Stop requested; waiting for native session exit confirmation.');
