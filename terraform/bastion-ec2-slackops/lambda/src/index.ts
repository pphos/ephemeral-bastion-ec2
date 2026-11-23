import { Logger } from '@aws-lambda-powertools/logger';
import { getParameter } from '@aws-lambda-powertools/parameters/ssm';
import { ListExecutionsCommand, SFNClient, StartExecutionCommand } from '@aws-sdk/client-sfn';
import type { APIGatewayProxyStructuredResultV2, LambdaFunctionURLEvent } from 'aws-lambda';
import { REPLY_TEXT, decide, reply, toExecutionName, type Action } from './slack-command';

const logger = new Logger({ serviceName: 'bastion-slack-command' });
const sfn = new SFNClient({});

// 環境変数がないのは設定の誤りなので、起動を失敗させる
const signingSecretParameterName = requireEnvironment('SIGNING_SECRET_PARAMETER_NAME');
const dedicatedChannelId = requireEnvironment('SLACK_CHANNEL_ID');
const stateMachineArn = requireEnvironment('STATE_MACHINE_ARN');

// Signing Secret を作り直したときに追いつけるよう、キャッシュは 5 分にする
const SIGNING_SECRET_MAX_AGE_SECONDS = 300;

export async function handler(
  event: LambdaFunctionURLEvent,
): Promise<APIGatewayProxyStructuredResultV2> {
  const signingSecret = await getParameter(signingSecretParameterName, {
    decrypt: true,
    maxAge: SIGNING_SECRET_MAX_AGE_SECONDS,
  }).catch((cause: unknown) => {
    logger.error('Failed to get the Slack signing secret', { cause });
    return undefined;
  });
  if (!signingSecret) {
    return { statusCode: 500 };
  }

  const decision = decide(event, signingSecret, dedicatedChannelId, new Date());
  switch (decision.kind) {
    case 'reject':
      logger.warn('Rejected the request', { reason: decision.reason });
      return { statusCode: decision.statusCode };
    case 'ignore':
      // ほかのチャンネルでは反応しない方針なので、応答の本文を返さない
      logger.info('Ignored a command from another channel', { channelId: decision.channelId });
      return { statusCode: 200 };
    case 'usage':
      return reply(REPLY_TEXT.usage);
    case 'run': {
      // 始められたら何も返さない。受け付けは、状態機械がチャンネルに投稿し、そのスレッドに経過を入れる
      const problem = await startWorkflow(decision.action, decision.userId);
      return problem === undefined ? { statusCode: 200 } : reply(problem);
    }
    default: {
      decision satisfies never;
      throw new Error('Unexpected decision');
    }
  }
}

// 実行を始められなかったときは、打った人に伝える文言を返す。AWS の失敗も、例外にせず文言にして利用者に知らせる
async function startWorkflow(action: Action, userId: string): Promise<string | undefined> {
  try {
    // 二重の開始を防ぐ。ListExecutions は結果整合なので、数秒以内の打ち直しはすり抜けることがある
    const running = await sfn.send(
      new ListExecutionsCommand({ stateMachineArn, statusFilter: 'RUNNING', maxResults: 1 }),
    );
    if ((running.executions ?? []).length > 0) {
      logger.info('Skipped starting because an execution is running', { action, userId });
      return REPLY_TEXT.busy;
    }

    const name = toExecutionName(action, userId, new Date());
    // 入力の形は、状態機械の定義（templates/state-machine.asl.json.tftpl）が読む形に合わせる
    await sfn.send(
      new StartExecutionCommand({
        stateMachineArn,
        name,
        input: JSON.stringify({ action, userId }),
      }),
    );
    logger.info('Started an execution', { action, userId, executionName: name });
    return undefined;
  } catch (cause) {
    logger.error('Failed to call Step Functions', { action, userId, cause });
    return REPLY_TEXT.unavailable;
  }
}

function requireEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing environment variable: ${name}`);
  }
  return value;
}
