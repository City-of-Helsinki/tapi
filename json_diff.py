#!/usr/bin/python
import json
import sys
import traceback
import md5
import re
import pprint
from deep_equal import deep_eq

def read_file(f):
    f['file'].seek(0)
    url = None
    contents = None
    for line in f['file'].readlines():
        if line == "\n" or line == "": continue
        if line == "URL:\n":
            contents = None
            url = None
        elif line == "CONTENTS:\n":
            contents = None
        else:
            if url is None:
                url = line.strip()
                continue
            if url is not None and contents is None:
                contents = line.strip()
        if not url or not contents:
            continue
        try:
            dct = json.loads(contents)
        except ValueError:
            # try to match jsonp
            m = re.match(r'[a-zA-Z0-9_]+\((.*)\);', contents)
            if m:
                try:
                    dct = json.loads(m.group(1))
                except ValueError:
                    dct = {'error': 'not json', 'content': contents}
        f['contents'][url] = dct

def main(left_file, right_file, ignore_fields):
    files = []
    with open(left_file, 'r') as fl:
     with open(right_file, 'r') as fr:
        files = [{"file": f, "contents": {}} for f in [fl, fr]]
        sums = set((md5.new(f['file'].read()).digest() for f in files))
        if len(sums) == 1:
            print('The files are exact matches.' )
            exit(0)

        for f in files:
            read_file(f)

    for url, payload in files[0]['contents'].iteritems():
        comparison = files[1]['contents'][url]
        match = deep_eq(payload, comparison)
        if match:
            continue
        print 'Mismatch!', url
        try:
            deep_eq(payload, comparison, _assert=True, ignore_fields=ignore_fields)
        except AssertionError as e:
            print files[0]['file'].name, 'doesn\'t match', files[1]['file'].name
            print(e.message)
            pprint.pprint(payload, indent=2)
            pprint.pprint(comparison, indent=2)
        except Exception as e:
            ex_type, ex, tb = sys.exc_info()
            traceback.print_tb(tb)
            print(e.message)
    print('Match!')
    exit(0)

if __name__ == '__main__':
    left_file = sys.argv[1]
    right_file = sys.argv[2]
    try:
        ignore_fields = sys.argv[3]
    except IndexError:
        ignore_fields = set()
    if ignore_fields:
        ignore_fields = set(map(lambda s: unicode(s.strip()), ignore_fields.split(',')))

    main(left_file, right_file, ignore_fields)
