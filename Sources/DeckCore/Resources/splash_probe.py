import argparse
import contextlib
import dataclasses
import io
import json
import math
import sys

def _jsonable(value):
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return 'inf' if math.isinf(value) else value
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return str(value)

def _type_name(action):
    function = getattr(action, 'type', None)
    if function is None:
        return None
    return {'name': getattr(function, '__name__', type(function).__name__), 'module': getattr(function, '__module__', None)}

def _action_kind(action):
    return type(action).__name__

def _load(root):
    sys.path.insert(0, root)
    instances = []
    original = argparse.ArgumentParser.__init__

    def recording(self, *args, **kwargs):
        original(self, *args, **kwargs)
        instances.append(self)
    argparse.ArgumentParser.__init__ = recording
    import install.launcher as launcher
    return (launcher, instances)

def _constants():
    found = {}
    sources = (('server.serve_options', ('MAX_YARN_CONTEXT_TOKENS', 'MAX_CONCURRENT_REQUESTS', 'DEFAULT_QUEUE_SIZE', 'DEFAULT_CONCURRENT_REQUESTS', 'DEFAULT_MAX_REQUEST_BYTES', 'DEFAULT_PORT')), ('server.images', ('MIN_PIXELS', 'MAX_PIXELS')), ('server.chat_format', ('REASONING_EFFORTS',)), ('server.protocol', ('SAMPLING_FIELDS', 'MAX_THINKING_END_TOKENS', 'STATUS_SCHEMA_VERSION')))
    import importlib
    for module_name, names in sources:
        try:
            module = importlib.import_module(module_name)
        except Exception:
            continue
        for name in names:
            if hasattr(module, name):
                found[f'{module_name}.{name}'] = _jsonable(getattr(module, name))
    return found

def schema(root):
    launcher, instances = _load(root)
    help_text = io.StringIO()
    version = None
    with contextlib.redirect_stdout(help_text):
        try:
            launcher.parse_args(['serve', '--help'])
        except SystemExit:
            pass
    try:
        version = launcher._version()
    except Exception as error:
        version = f'n/d: {error}'
    serve = next((p for p in instances if p.prog.endswith(' serve')), None)
    if serve is None:
        return {'error': 'il lanciatore non ha costruito il parser di serve'}
    groups = {}
    for group in serve._action_groups:
        for action in group._group_actions:
            groups[id(action)] = group.title
    metadata = {}
    try:
        from server import serve_options
        for option in getattr(serve_options, 'SERVE_OPTIONS', ()):
            engine = getattr(option, 'engine', None)
            metadata[option.flag] = {'group_key': getattr(option, 'group', None), 'environment': getattr(option, 'environment', None), 'secret': bool(getattr(option, 'secret', False)), 'needs': getattr(option, 'needs', None), 'engine': None if engine is None else {'at': engine.at, 'required': bool(getattr(engine, 'required', False))}}
    except Exception as error:
        metadata = {'__error__': str(error)}
    launcher_needs = {}
    with contextlib.suppress(Exception):
        from install import families
        launcher_needs = dict(getattr(families, 'LAUNCHER_NEEDS', {}))
    options = []
    for action in serve._actions:
        if not action.option_strings or isinstance(action, argparse._HelpAction):
            continue
        options.append({'flags': list(action.option_strings), 'dest': action.dest, 'action': _action_kind(action), 'nargs': _jsonable(action.nargs), 'const': _jsonable(action.const), 'default': _jsonable(action.default), 'required': bool(action.required), 'choices': None if action.choices is None else [_jsonable(c) for c in action.choices], 'metavar': _jsonable(action.metavar), 'help': action.help, 'group': groups.get(id(action)), 'type': _type_name(action)})
    return {'version': version, 'help': help_text.getvalue(), 'options': options, 'serve_options': metadata, 'launcher_needs': launcher_needs, 'constants': _constants()}

def families_report(root):
    sys.path.insert(0, root)
    from install import families, models
    engine = json.loads(models.run_engine(['families'], 'family report'))
    report = families.option_report(engine) if hasattr(families, 'option_report') else None
    facts = {}
    for family in families.FAMILIES:
        own = dict(engine.get(family.name, {}))
        own['vision'] = getattr(family, 'vision', None)
        chat_format = getattr(family, 'chat_format', None)
        own['reasoning_switch'] = getattr(chat_format, 'reasoning_switch', None)
        own['prompt_switches_reasoning'] = getattr(chat_format, 'prompt_switches_reasoning', None)
        sampling = getattr(family, 'sampling', None)
        if sampling is not None and dataclasses.is_dataclass(sampling):
            own['sampling'] = dataclasses.asdict(sampling)
        facts[family.name] = own
    return {'report': report, 'facts': facts}

def validate(root, argv):
    launcher, _ = _load(root)
    from server import serve_options
    try:
        args = launcher.parse_args(argv)
    except SystemExit as refusal:
        message = getattr(refusal, 'message', None)
        return {'ok': False, 'message': message if message is not None else f'exit {refusal.code}'}
    if args.command != 'serve':
        return {'ok': False, 'message': 'non è una riga di serve'}
    result = {'ok': True, 'port': args.port, 'model': args.model}
    secrets = {o.dest for o in getattr(serve_options, 'SERVE_OPTIONS', ()) if getattr(o, 'secret', False)}
    result['parsed'] = {key: _jsonable(value) for key, value in vars(args).items() if key not in secrets and key != 'client_args'}
    with contextlib.suppress(Exception):
        result['server_argv'] = serve_options.serve_argv(args)
    with contextlib.suppress(Exception):
        result['engine_argv'] = serve_options.engine_argv(args)
    return result

def main():
    command, root, *rest = sys.argv[1:]
    if command == 'schema':
        out = schema(root)
    elif command == 'families':
        out = families_report(root)
    elif command == 'validate':
        if rest[:1] == ['--']:
            rest = rest[1:]
        with contextlib.redirect_stderr(io.StringIO()):
            out = validate(root, rest)
    else:
        out = {'error': f'comando sconosciuto {command}'}
    sys.stdout.write(json.dumps(out))
    return 0
if __name__ == '__main__':
    raise SystemExit(main())
