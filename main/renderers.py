from rest_framework.renderers import BaseRenderer

import csv
import io
import ujson

from collections import OrderedDict

class CsvRenderer(BaseRenderer):
    """ renders an object (list of objects) to a CSV file """
    media_type = 'text/plain'
    format = 'csv'

    def render(self, listObj, media_type=None, renderer_context=None):
        """ Flattens list of objects into a CSV """
        temp_file=io.StringIO()
        temp_list=[]
        return_value="No Records found."
        try:
            if len(listObj) > 0:
                field_names=listObj[0].keys()
                for entry in listObj:
                    row_object={}
                    for field in field_names:
                        if type(entry[field]) in [OrderedDict, dict]:
                            row_object.update(entry[field])
                        else:
                            row_object[field] = entry[field]
                    temp_list.append(row_object)
                field_names=temp_list[0].keys()
                writer=csv.DictWriter(temp_file,
                                      fieldnames=field_names,
                                      extrasaction='ignore')
                writer.writeheader()
                writer.writerows(temp_list)
                return_value=temp_file.getvalue()
        except Exception as e:
            return_value=str(e)
        finally:
            return return_value

class UJsonRenderer(BaseRenderer):
    """ Uses ujson instead of json to serialize an object """
    media_type = 'application/json'
    format = 'json'

    def render(self, obj, media_type=None, renderer_context=None):
        return ujson.dumps(obj, ensure_ascii=True, escape_forward_slashes=False)
