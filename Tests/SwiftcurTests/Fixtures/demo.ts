import { Cli, z } from '/tmp/incur/src/index.ts'

const users = Cli.create('users', { description: 'Manage users' })
  .command('list', {
    description: 'List users',
    options: z.object({ limit: z.number().default(10).describe('Max users') }),
    output: z.object({ users: z.array(z.object({ id: z.number(), name: z.string() })) }),
    mcp: { annotations: { readOnlyHint: true } },
    run(c) {
      const all = [{ id: 1, name: 'Alice' }, { id: 2, name: 'Bob' }, { id: 3, name: 'Carol' }]
      return { users: all.slice(0, c.options.limit) }
    },
  })
  .command('get', {
    description: 'Get a user',
    args: z.object({ id: z.number().describe('User ID') }),
    run(c) {
      if (c.args.id !== 1) return c.error({ code: 'NOT_FOUND', message: `No user ${c.args.id}`, cta: { commands: ['users list'] } })
      return { id: 1, name: 'Alice' }
    },
  })
  .command('delete', {
    description: 'Delete a user',
    destructive: true,
    args: z.object({ id: z.number() }),
    run(c) { return { deleted: c.args.id } },
  })

const cli = Cli.create('demo', {
  description: 'Demo CLI',
  version: '1.2.3',
  env: z.object({ DEMO_TOKEN: z.string().optional().describe('API token') }),
  globals: z.object({ debug: z.boolean().default(false).describe('Verbose output') }),
  globalAlias: { debug: 'v' },
  config: { flag: 'config', files: ['demo.json'] },
  sync: { suggestions: ['list my users'], body: 'Run demo whoami to check setup.' },
  vars: z.object({ user: z.string().default('none') }),
  banner: { render: () => 'DEMO BANNER', mode: 'human' },
  mcp: { instructions: 'Use demo tools.', ...(process.env.DEMO_DIRECT ? { tools: { discovery: 'direct' as const } } : {}) },
})
  .use(async (c, next) => {
    if (c.command === 'guarded' && !c.env.DEMO_TOKEN)
      return c.error({ code: 'AUTH', message: 'token required', cta: { commands: ['whoami'] } })
    c.set('user', 'mw')
    await next()
  })
  .command('greet', {
    description: 'Greet someone',
    aliases: ['hi'],
    args: z.object({ name: z.string().describe('Name to greet') }),
    options: z.object({
      loud: z.boolean().default(false).describe('Shout'),
      times: z.number().default(1).describe('Repeat count'),
      style: z.enum(['plain', 'fancy']).optional().describe('Style'),
      old: z.string().optional().describe('Old flag').meta({ deprecated: true }),
      tag: z.array(z.string()).default([]).describe('Tags'),
    }),
    alias: { loud: 'l', times: 't' },
    examples: [{ args: { name: 'world' }, description: 'Greet the world' }, { args: { name: 'bob' }, options: { loud: true } }],
    hint: 'Names are case-sensitive.',
    output: z.object({ message: z.string() }),
    run(c) {
      let message = `hello ${c.args.name}`.repeat(c.options.times)
      if (c.options.loud) message = message.toUpperCase()
      return c.ok({ message }, { cta: { commands: ['users list', { command: 'greet', args: { name: true }, description: 'greet again' }] } })
    },
  })
  .command(users)
  .command('stream', {
    description: 'Stream steps',
    async *run() {
      yield { step: 1 }
      yield { step: 2 }
    },
  })
  .command('fail', { description: 'Always fails', run() { throw new Error('boom') } })
  .command('whoami', {
    description: 'Show env and globals',
    env: z.object({ DEMO_USER: z.string().default('anon').describe('User name') }),
    run(c) { return { user: c.env.DEMO_USER, debug: c.globals.debug, agent: c.agent } },
  })
  .command('tags', {
    description: 'Echo tags',
    args: z.object({ first: z.string(), rest: z.array(z.string()).optional() }),
    options: z.object({ v: z.number().default(0).meta({ count: true }).describe('Verbosity') }),
    run(c) { return { first: c.args.first, rest: c.args.rest ?? [], v: c.options.v } },
  })
  .command(process.env.DEMO_EXTRA ? 'extra' : 'text2', { description: 'Extra', run() { return 1 } })
  .command('text', { description: 'Returns text', run() { return 'plain text' } })
  .command('quiet', { description: 'Agent-only output', outputPolicy: 'agent-only', run() { return { secret: 42 } } })
  .command('guarded', { description: 'Needs a token', run(c) { return { user: c.var.user } } })
  .command('exit42', { description: 'Custom exit', run(c) { return c.error({ code: 'CUSTOM', message: 'custom failure', exitCode: 42, retryable: true }) } })
  .command(Cli.create('ping', { description: 'Ping', run() { return { pong: true } } }))
  .command(Cli.create('admin', { description: 'Admin tools', outputPolicy: 'agent-only' })
    .command('stats', { description: 'Show stats', run() { return { count: 3 } } }))
  .command('fmt', { description: 'Defaults to JSON', format: 'json', run() { return { a: 1 } } })
  .command('port', { description: 'Needs a port', env: z.object({ DEMO_PORT: z.number().describe('Port number') }), run(c) { return { port: c.env.DEMO_PORT } } })
  .command('usage', {
    description: 'Custom usage',
    args: z.object({ file: z.string().optional() }),
    options: z.object({ stdin: z.boolean().default(false) }),
    usage: [{ args: { file: true } }, { prefix: 'cat x |', options: { stdin: true }, suffix: '# from stdin' }],
    run(c) { return { file: c.args.file ?? null, stdin: c.options.stdin } },
  })
  .command('page', { description: 'Pages', options: z.object({ page: z.number().int().min(1).default(1).describe('Page') }), run(c) { return { page: c.options.page } } })

cli.serve()

