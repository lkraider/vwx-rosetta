# Pre-export program. The export tool replaces /Volumes/volxxxx/Caches/tmp/rosetta-vw-empty-repair-20261016/runs/20261016T235158-ui-pdf/pre/ix.mech.viewport-crop-annotation-visibility.pdf.vector.json with the result path.
# The result holds status ok or error, the summary of what changed, and any call errors.
import json, os, traceback, vs
OUT = '/Volumes/volxxxx/Caches/tmp/rosetta-vw-empty-repair-20261016/runs/20261016T235158-ui-pdf/pre/ix.mech.viewport-crop-annotation-visibility.pdf.vector.json'
res = {'status': 'error', 'errors': [], 'summary': {}}
def t(label, fn):
    try:
        return fn()
    except Exception as e:
        res['errors'].append('%s: %r' % (label, e))
        return None
def L(x):
    if isinstance(x, (list, tuple)):
        return [L(v) for v in x]
    if isinstance(x, (int, float, str, bool)) or x is None:
        return x
    return repr(x)
def info(h):
    d = {'type': vs.GetTypeN(h), 'name': vs.GetName(h)}
    d['bbox'] = t('GetBBox', lambda: L(vs.GetBBox(h)))
    d['3dinfo'] = t('Get3DInfo', lambda: L(vs.Get3DInfo(h)))
    d['volume'] = t('CalcVolume', lambda: vs.CalcVolume(h))
    return d
def extent(h):
    (x0, y0), (x1, y1) = vs.GetBBox(h)
    return abs(x1 - x0) * abs(y1 - y0)
def done():
    tmp = OUT + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(res, f, indent=1)
    os.replace(tmp, OUT)
try:
    vp = vs.GetObject('viewport-b')
    res['summary']['before'] = {c: L(vs.GetVPClassVisibility(vp, c)) for c in ('None', 'Dimension')}
    for c in ('None', 'Dimension'):
        vs.SetVPClassVisibility(vp, c, 0)
    vs.UpdateVP(vp)
    vs.ResetObject(vp)
    vs.ReDrawAll()
    res['summary']['after'] = {c: L(vs.GetVPClassVisibility(vp, c)) for c in ('None', 'Dimension')}
    res['summary']['viewport'] = info(vp)
    res['status'] = 'ok' if res['summary']['after']['None'][1] == 0 else 'error'
except Exception:
    res['status'] = 'error'
    res['errors'].append(traceback.format_exc())
done()
