// `dsh-diag-prompt`: diagnostic only. The UI reports "agent busy" for ANY
// exception thrown while a prompt is admitted (session-controller turns it into
// `session/agent-busy "prompt rejected"` and puts the real error only in
// `details.reason`, which the UI does not show). This wraps the admission call and
// writes the real reason to the app's node log, one line per failure:
//
//   diag-prompt: REJECTED code=<code> reason=<message> at <top stack frames>
//
// It logs error text and code only: never the request, its content, headers,
// credentials or environment. Remove it (profile row `diag-prompt`) once the
// cause is fixed.

export const name = 'diag-prompt';

const clip = (value, max = 700) => String(value ?? '').replace(/\s+/g, ' ').slice(0, max);

export function apply(ctx) {
  const controller = ctx.get('sessionController');
  const commands = controller?.commands;
  if (commands === undefined || typeof commands.prompt !== 'function') {
    process.stdout.write('diag-prompt: sessionController.commands.prompt not found; not installed\n');
    return;
  }
  const original = commands.prompt.bind(commands);
  commands.prompt = async (request, source) => {
    try {
      const result = await original(request, source);
      process.stdout.write('diag-prompt: accepted\n');
      return result;
    } catch (error) {
      const stack = String(error?.cause?.stack ?? error?.stack ?? '').split('\n').slice(0, 4).join(' | ');
      process.stdout.write(
        `diag-prompt: REJECTED code=${clip(error?.code, 80)} message=${clip(error?.message, 200)} `
        + `reason=${clip(error?.details?.reason ?? error?.data?.reason, 700)} cause=${clip(error?.cause, 300)} at ${clip(stack, 600)}\n`,
      );
      throw error;
    }
  };
  process.stdout.write('diag-prompt: installed\n');
}

export default { name, apply, inject: ['sessionController'] };
