import contextlib
import io
import json
import math
import sys
import time
from pathlib import Path

def links(root, models_dir):
    sys.path.insert(0, root)
    import install.launcher as launcher
    from install import local, models
    requests = json.load(sys.stdin)
    out = []
    for argv in requests:
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                args = launcher.parse_args(argv)
        except SystemExit as refusal:
            out.append({'error': str(getattr(refusal, 'message', None) or f'exit {refusal.code}')})
            continue
        models_root = Path(models_dir).expanduser().resolve()
        if getattr(args, 'model_dir', None) is not None:
            draft = args.draft_model and local._path(args.draft_model)
            mmproj = args.mmproj and local._path(args.mmproj)
            link = models.local_selection_link(models_root, local._path(args.model_dir), draft, mmproj, args.language_only)
        else:
            link = models.Selection.of(models_root, args.model, revision=args.revision, language_only=args.language_only, draft_model=args.draft_model).link
        out.append({'link': str(link)})
    return {'links': out}

def verify(root, link, full):
    sys.path.insert(0, root)
    from install import assembly
    began = time.monotonic()
    try:
        assembly.verify(Path(link), full=full)
    except Exception as error:
        return {'ok': False, 'message': str(error), 'seconds': time.monotonic() - began}
    return {'ok': True, 'seconds': time.monotonic() - began}

def gguf(root, files):
    sys.path.insert(0, root)
    from install import gguf as reader
    out = {}
    for name in files:
        try:
            header = reader.Metadata(name, tensors=True)
        except Exception as error:
            out[name] = {'error': str(error)}
            continue
        values = header.values
        architecture = values.get('general.architecture')
        types = {}
        for tensor, kind in header.tensors.items():
            label = reader.TENSOR_TYPES.get(kind, str(kind))
            types[label] = types.get(label, 0) + math.prod(header.extents[tensor])
        context = values.get(f'{architecture}.context_length') if isinstance(architecture, str) else None
        label = values.get('general.size_label')
        out[name] = {'architecture': architecture if isinstance(architecture, str) else None, 'name': values.get('general.name') if isinstance(values.get('general.name'), str) else None, 'context_length': context if isinstance(context, int) else None, 'types': types, 'size_label': label if isinstance(label, str) else None}
    return {'files': out}

def main():
    command, root, *rest = sys.argv[1:]
    if command == 'links':
        out = links(root, rest[0])
    elif command == 'verify':
        out = verify(root, rest[0], '--full' in rest[1:])
    elif command == 'gguf':
        out = gguf(root, rest)
    else:
        out = {'error': f'comando sconosciuto {command}'}
    sys.stdout.write(json.dumps(out))
    return 0
if __name__ == '__main__':
    raise SystemExit(main())
