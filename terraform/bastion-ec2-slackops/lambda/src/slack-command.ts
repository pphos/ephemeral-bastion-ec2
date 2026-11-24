import { createHmac, timingSafeEqual } from 'node:crypto';
import type { APIGatewayProxyStructuredResultV2, LambdaFunctionURLEvent } from 'aws-lambda';

// Slack のスラッシュコマンド /bastion を、どう扱うかを決める。I/O を持たないので、ここだけでテストできる

// /bastion の引数。状態機械の入力の action にも、同じ値を使う
export const ACTION = {
  start: 'start',
  stop: 'stop',
} as const;

export type Action = (typeof ACTION)[keyof typeof ACTION];

export type Decision =
  // reason はログで原因を追うためのもので、Slack には返さない
  | Readonly<{ kind: 'reject'; statusCode: 400 | 401; reason: string }>
  | Readonly<{ kind: 'ignore'; channelId: string }>
  | Readonly<{ kind: 'usage' }>
  | Readonly<{ kind: 'run'; action: Action; userId: string }>;

export const REPLY_TEXT = {
  usage: [
    '*使い方*',
    '• `/bastion start`: 踏み台サーバーを起動する',
    '• `/bastion stop`: 踏み台サーバーを終了する',
  ].join('\n'),
  busy: '前の起動または終了が終わっていません。終わってから、もう一度実行してください。',
  unavailable: 'エラーのため、受け付けられませんでした。管理者に連絡してください。',
} as const;

// Slack のドキュメントの例に合わせ、タイムスタンプが 5 分以上ずれたリクエストは拒否する（リプレイ対策）
const MAX_TIMESTAMP_SKEW_SECONDS = 60 * 5;

// 署名は "v0:<タイムスタンプ>:<本文>" の HMAC-SHA256 なので、本文は分解する前に確かめる
export function decide(
  event: LambdaFunctionURLEvent,
  signingSecret: string,
  dedicatedChannelId: string,
  now: Date,
): Decision {
  // Function URL では、本文が Base64 で届くことがある
  const rawBody = event.isBase64Encoded
    ? Buffer.from(event.body ?? '', 'base64').toString('utf8')
    : (event.body ?? '');

  // Function URL のイベントでは、ヘッダー名は小文字になる
  const signature = event.headers['x-slack-signature'];
  const timestamp = event.headers['x-slack-request-timestamp'];
  if (!signature || !timestamp || !/^\d+$/.test(timestamp)) {
    return { kind: 'reject', statusCode: 401, reason: 'missing-signature' };
  }
  if (Math.abs(now.getTime() / 1000 - Number(timestamp)) > MAX_TIMESTAMP_SKEW_SECONDS) {
    return { kind: 'reject', statusCode: 401, reason: 'stale-timestamp' };
  }
  const expected = Buffer.from(
    `v0=${createHmac('sha256', signingSecret).update(`v0:${timestamp}:${rawBody}`).digest('hex')}`,
  );
  const actual = Buffer.from(signature);
  // timingSafeEqual は長さが違うと例外になるので、先に長さを比べる
  if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) {
    return { kind: 'reject', statusCode: 401, reason: 'signature-mismatch' };
  }

  // 本文は JSON ではなく application/x-www-form-urlencoded で届く。引数がなければ text は空になる
  const params = new URLSearchParams(rawBody);
  const text = params.get('text');
  const channelId = params.get('channel_id');
  const userId = params.get('user_id');
  if (text === null || !channelId || !userId) {
    return { kind: 'reject', statusCode: 400, reason: 'invalid-slash-command' };
  }

  if (channelId !== dedicatedChannelId) {
    return { kind: 'ignore', channelId };
  }
  const word = text.trim().toLowerCase();
  const action = Object.values(ACTION).find((value) => value === word);
  return action === undefined ? { kind: 'usage' } : { kind: 'run', action, userId };
}

/**
 * 状態機械の実行名。調べるときに、操作と打った人と時刻が分かるようにする。
 * CloudWatch Logs で扱えるよう、英数字と - だけで作る（Slack のユーザー ID は英数字）
 */
export function toExecutionName(action: Action, userId: string, now: Date): string {
  return `${action}-${userId}-${now.getTime()}`;
}

// 使い方や受け付けられなかった理由は、打った人にだけ見せる。チャンネルには、状態機械の投稿だけを並べる
export function reply(text: string): APIGatewayProxyStructuredResultV2 {
  return {
    statusCode: 200,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ response_type: 'ephemeral', text }),
  };
}
