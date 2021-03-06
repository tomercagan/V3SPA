import logging
logger = logging.getLogger(__name__)

import restful
import refpolicy
import api.handlers.ws_domains as ws_domains
import api


def get_dsl_for_policy(refpol, dynamic_policy):
    """ Get the web service to tranlate the provided policy (with associated
    refpolicy) into the Lobster DSL """

    translate_args = {
        'refpolicy': refpol.id,
        'modules': []
    }

    if dynamic_policy['modified'] is True:
        # If None, it means this module has not be modified
        translate_args['modules'].append({
            'name': dynamic_policy.id,
            'if': dynamic_policy['documents']
            .get('if', {}).get('text', ""),
            'te': dynamic_policy['documents']
            .get('te', {}).get('text', ""),
            'fc': dynamic_policy['documents']
            .get('fc', {}).get('text', "")
        })

    dsl = ws_domains.call(
        'lobster',
        'translate_selinux',
        translate_args)

    if len(dsl['errors']) > 0:
      raise Exception("Failed to translate DSL: {0}"
                      .format("\n".join(
                          ("{0}".format(x) for x in dsl['errors']))))

    dynamic_policy['documents']['dsl'] = {
        'text': dsl['result'],
        'mode': 'lobster'
    }

    dynamic_policy.Insert()


class Policy(restful.ResourceDomain):
    TABLE = 'policies'

    @classmethod
    def do_create(cls, params, response):
        refpol = refpolicy.RefPolicy.Read(params['refpolicy_id'])

        modname, version = refpolicy.extract_module_version(
            params['documents']['te']['text'])

        if modname in refpol['modules']:
            raise Exception("'{0}' is already a module in '{1}'".format(
                modname, refpol['id']))

        params['id'] = modname
        params['modified'] = True  # by definition
        policy = cls(params)
        get_dsl_for_policy(refpol, policy)

        refpol['modules'][modname] = {
            'name': modname,
            'version': version,
            'policy_id': policy._id,
            'te_file': None,
            'fc_file': None,
            'if_file': None
        }

        refpol.Update()

        response['payload'] = policy
        return response

    @classmethod
    def do_update(cls, params, response):
      if '_id' in params and params['_id'] is not None:
          newobject = cls.Read(params['_id'])
          response['payload'] = newobject.Update(params)
      else:
          newobject = cls(params)
          response['payload'] = newobject.Insert()

      refpol = refpolicy.RefPolicy.Read(params['refpolicy_id'])
      refpol['modules'][newobject.id] = {
          'name': newobject.id,
          'version': 1.0,
          'policy_id': newobject._id,
          'te_file': None,
          'fc_file': None,
          'if_file': None
      }

      refpol.Update()
      return response

    @classmethod
    def do_get(cls, params, response):

        if 'refpolicy_id' in params:
            params['refpolicy_id'] = api.db.idtype(params['refpolicy_id'])

        refpol = refpolicy.RefPolicy.Read(params['refpolicy_id'])
        module = refpol['modules'][params['id']]

        logger.warning("Looking for policy {0}".format(params['id']))
        dynamic_policy = cls.Read(module['policy_id'])
        logger.warning("Found {0}".format(dynamic_policy))

        # If the dynamic_policy is none, that means that it's a module
        # belonging to the reference policy, but hasn't been edited before.
        if dynamic_policy is None:

            dynamic_policy_data = {
                'id': params['id'],
                'refpolicy_id': params['refpolicy_id'],
                'modified': False,
                'documents':
                refpolicy.read_module_files(
                    module,
                    editable=False),
                'type': 'selinux'
            }

            dynamic_policy = cls(dynamic_policy_data)

        if 'dsl' not in dynamic_policy['documents']:
            # If the dsl doesn't exist, then we need to load it. However, we
            # need to load it with respect to the type of module this is (i.e. if
            # it's already present in the reference policy on disk
            get_dsl_for_policy(refpol, dynamic_policy)

        # save the policy_id
        refpol['modules'][params['id']]['policy_id'] = dynamic_policy._id
        refpol.Insert()

        response['payload'] = dynamic_policy
        return response


def __instantiate__():
    return Policy
