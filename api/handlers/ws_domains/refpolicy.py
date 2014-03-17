import logging
logger = logging.getLogger(__name__)

import base64
import os
import re

import restful
import api


def iter_lines(fil_or_str):
  if isinstance(fil_or_str, (basestring)):
    fil_or_str = fil_or_str.split('\n')

  for line in fil_or_str:
    yield line


def extract_module_version(module_text):
    """ Extracts the name and version from a module TE file """
    mod_defn_re = re.compile(
        r'policy_module\((?P<name>[a-zA-Z0-9\.\/_-]+),\s*(?P<version>[0-9]+\.[0-9]+(:?\.[0-9]+)?)\)')

    for line in iter_lines(module_text):
      match = mod_defn_re.match(line)
      if match:
        return match.group('name'), match.group('version')

    else:  # no matches
      raise Exception(".te file had no module string")


def read_module_files(module_data):
  """ Read the files belonging to a module from disk and return
  their data as a dictionary. """

  files = {}

  if 'te_file' in module_data:
    with open(module_data['te_file']) as fin:
      files['te'] = fin.read()

  if 'if_file' in module_data:
    with open(module_data['if_file']) as fin:
      files['if'] = fin.read()

  if 'fc_file' in module_data:
    with open(module_data['fc_file']) as fin:
      files['fc'] = fin.read()

  return files


class RefPolicy(restful.ResourceDomain):
    TABLE = 'refpolicy'

    @classmethod
    def do_upload_chunk(cls, params, response):
        # Make sure the directory exists
        try:
            os.makedirs(os.path.join(
                api.config.get('storage', 'bulk_storage_dir'),
                'tmp'))
        except:
            pass

        metadata = cls.Read({'id': params['name']})
        print params['index']
        print metadata

        if metadata is None:
            metadata = cls({
                'id': params['name'],
                'written': params['index'],
                'total': params['total'],
                'tmpfile': os.path.join(
                    api.config.get('storage', 'bulk_storage_dir'),
                    "tmp",
                    params['name']
                )
            })

        elif 'tmpfile' not in metadata and 'disk_location' in metadata:
            raise Exception('Policy already exists')
        elif metadata['written'] < params['index']:
            os.remove(metadata['tmpfile'])
            metadata.Delete()
            raise Exception("Received out-of-order chunk. "
                            "Expected {0}. Got {1}"
                            .format(metadata['written'], params['index']))

        metadata['written'] = params['index']

        mode = 'r+b' if os.path.exists(metadata['tmpfile']) else 'wb'

        with open(metadata['tmpfile'], mode) as fout:
            fout.seek(params['index'])
            raw_data = base64.b64decode(params['data'])
            fout.write(raw_data)
            fout.flush()

        metadata['written'] += params['length']
        if metadata['written'] == metadata['total']:
            try:
                metadata.extract_zipped_policy()
                metadata['modules'] = metadata.read_policy_modules()
            except Exception:
                metadata.Delete()
                raise
            else:
                metadata['valid'] = True
        metadata.Insert()

        response['payload'] = {
            'progress': float(metadata['written']) / float(metadata['total']),
            'info': {
                '_id': metadata['_id'],
                'id': metadata['id']
            }
        }

        return response

    def read_policy_modules(self):
        """ Read an extracted policy off the disk, and understand what modules
        are included in it (and where they are on disk).
        """
        policy_dir = os.path.join(
            api.config.get('storage', 'bulk_storage_dir'),
            'refpolicy', self['id'])

        def print_error(e):
            print(e)

        walker = os.walk(os.path.join(policy_dir, 'policy/modules'),
                         onerror=print_error)

        modules = {}

        for dirpath, dirnames, filenames in walker:
            modnames = set((fn.split('.')[0] for fn in filenames))

            for mod in modnames:
                with open(os.path.join(dirpath, mod + ".te")) as te_file:
                  try:
                    modname, version = extract_module_version(te_file)
                  except Exception:
                    raise

                if modname in modules:
                    raise Exception(
                        "Reference policy contains duplicate "
                        "module: '{0}'".format(modname)
                    )

                modules[modname] = {
                    'name': modname,
                    'version': version,
                    'te_file':
                    os.path.join(dirpath, mod + ".te"),
                    'fc_file':
                    os.path.join(
                        dirpath,
                        mod + ".fc") if mod + ".fc" in filenames else None,
                    'if_file':
                    os.path.join(
                        dirpath,
                        mod + ".if") if mod + ".if" in filenames else None
                }

        return modules

    def extract_zipped_policy(self):
        """ Validate that the uploaded file is actually a policy.

        Unpack it, identify that it is actually a reference policy,
        and determine what modules it contains.
        """
        import zipfile

        name = self['id'][:-4] if self['id'].endswith('.zip') else self['id']
        zipped_policy = self['tmpfile']
        policy_dir = os.path.join(
            api.config.get('storage', 'bulk_storage_dir'),
            'refpolicy')

        if not zipfile.is_zipfile(zipped_policy):
            raise Exception("Unable to extract: file was not a ZIP archive")

        try:
            zf = zipfile.ZipFile(zipped_policy)
        except zipfile.BadZipfile:
            raise Exception("Unable to extract: file corrupted")

        try:
            zf.getinfo('{0}/policy/modules.conf'.format(name))
            zf.getinfo('{0}/policy/modules/'.format(name))
        except KeyError:
            raise Exception("File does not appear to contain "
                            "SELinux reference policy source")

        zf.extractall(policy_dir)

        self['disk_location'] = policy_dir
        os.remove(zipped_policy)
        del self['tmpfile']
        self['id'] = name


def __instantiate__():
    return RefPolicy
