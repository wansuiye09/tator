from django.views import View
from django.views.generic.base import TemplateView
from django.shortcuts import render_to_response
from django.shortcuts import redirect
from django.shortcuts import get_object_or_404
from django.contrib.auth.mixins import LoginRequiredMixin
from django.core.exceptions import PermissionDenied
from django.http import HttpResponse
from rest_framework.authtoken.models import Token
from django.contrib.auth.models import AnonymousUser

from .models import Project
from .models import EntityMediaBase
from .models import EntityMediaImage
from .models import EntityMediaVideo
from .models import Membership

from .notify import Notify
import os
import logging

import sys
import traceback

# Load the main.view logger
logger = logging.getLogger(__name__)

class MainRedirect(View):
    def dispatch(self, request, *args, **kwargs):
        if request.user.is_authenticated:
            return redirect('projects')
        else:
            return redirect('accounts/login')

class ProjectsView(LoginRequiredMixin, TemplateView):
    template_name = 'projects.html'

class CustomView(LoginRequiredMixin, TemplateView):
    template_name = 'new-project/custom.html'

class ProjectBase(LoginRequiredMixin):

    def get_context_data(self, **kwargs):
        # Get project info.
        context = super().get_context_data(**kwargs)
        project = get_object_or_404(Project, pk=self.kwargs['project_id'])
        context['project'] = project

        # Check if user is part of project.
        if not project.has_user(self.request.user.pk):
            raise PermissionDenied
        return context

class ProjectDetailView(ProjectBase, TemplateView):
    template_name = 'project-detail.html'

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        token, _ = Token.objects.get_or_create(user=self.request.user)
        context['token'] = token
        return context

class ProjectSettingsView(ProjectBase, TemplateView):
    template_name = 'project-settings.html'

class AnnotationView(ProjectBase, TemplateView):
    template_name = 'annotation.html'

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        media = get_object_or_404(EntityMediaBase, pk=self.kwargs['pk'])
        context['media'] = media
        return context


def validate_project(user, project):
    granted = False
    if isinstance(user, AnonymousUser):
        granted = False
    else:
        # Find membership for this user and project
        membership = Membership.objects.filter(
            user=user,
            project=project
        )

        # If user is not part of project, deny access
        if membership.count() == 0:
            granted = False
        else:
            granted = True

    return granted

class AuthMediaView(View):
    def dispatch(self, request, *args, **kwargs):
        """ Identifies permissions for a file in /media

        User must be part of the project to access media files.
        Returns 200 on OK, returns 403 on Forbidden
        """

        original_url = request.headers['X-Original-URI']
        filename = os.path.basename(original_url)

        # Unautherized users are rejected
        if not request.user.is_authenticated:
            msg = f"Anonymous access attempt to '{original_url}'"
            Notify.notify_admin_msg(msg)
            return HttpResponse(status=403)

        # Filename could be a thumbnail, thumbnail_gif, or url
        extension = os.path.splitext(filename)[-1]

        # If it is a JSON avoid a database query and supply segment
        # info file as nothing sensitive is in there
        if extension == '.json':
            return HttpResponse(status=200)

        # Find a matching object
        match_object = None
        media_match = EntityMediaBase.objects.filter(file__exact=filename)
        video_thumb_match = EntityMediaVideo.objects.filter(thumbnail__exact=filename)
        video_thumb_gif_match = EntityMediaVideo.objects.filter(thumbnail_gif__exact=filename)
        image_thumb_match = EntityMediaImage.objects.filter(thumbnail__exact=filename)
        if media_match.count():
            match_object = media_match[0]
        elif video_thumb_match.count():
            match_object = video_thumb_match[0]
        elif video_thumb_gif_match.count():
            match_object = video_thumb_gif_match[0]
        elif image_thumb_match.count():
            match_object = image_thumb_match[0]

        if match_object:
            authorized = validate_project(request.user, match_object.project)
            if authorized:
                return HttpResponse(status=200)
            else:
                # Files that aren't in the whitelist or database are forbidden
                msg = f"({request.user}/{request.user.id}): "
                msg += f"Attempted to access unauthorized file '{original_url}'"
                msg += f". "
                msg += f"Does not have access to '{match_object.project.name}'"
                Notify.notify_admin_msg(msg)
                return HttpResponse(status=403)
        else:
            # Files that aren't in the whitelist or database are forbidden
            msg = f"({request.user}/{request.user.id}): "
            msg += f"Attempted to access unrecorded file '{original_url}'"
            Notify.notify_admin_msg(msg)
            return HttpResponse(status=403)

        return HttpResponse(status=403)


class AuthRawView(View):
    def dispatch(self, request, *args, **kwargs):
        """ Identifies permissions for a file in /raw
        Returns 200 on OK, returns 403 on Forbidden
        """

        # Unautherized users are rejected
        if not request.user.is_authenticated:
            msg = f"Anonymous access attempt to '{original_url}'"
            Notify.notify_admin_msg(msg)
            return HttpResponse(status=403)

        original_url = request.headers['X-Original-URI']
        filename = os.path.basename(original_url)

        # Filename could be a original
        match_object = None
        video_original_match = EntityMediaVideo.objects.filter(original__exact=original_url)
        if video_original_match.count():
            match_object = video_original_match[0]

        if match_object:
            authorized = validate_project(request.user, match_object.project)
            if authorized:
                return HttpResponse(status=200)
            else:
                # Files that aren't in the whitelist or database are forbidden
                msg = f"({request.user}/{request.user.id}): "
                msg += f"Attempted to access unauthorized file '{original_url}'"
                msg += f". "
                msg += f"Does not have access to '{match_object.project.name}'"
                Notify.notify_admin_msg(msg)
                return HttpResponse(status=403)
        else:
            # Files that aren't in the whitelist or database are forbidden
            msg = f"({request.user}/{request.user.id}): "
            msg += f"Attempted to access unrecorded file '{original_url}'"
            Notify.notify_admin_msg(msg)
            return HttpResponse(status=403)

        return HttpResponse(status=403)

def ErrorNotifierView(request, code,message,details=None):

    context = {}
    context['code'] = code
    context['msg'] = message
    context['details'] = details
    response=render_to_response('error-page.html', context)
    response.status_code = code

    # Generate slack message
    if Notify.notification_enabled():
        msg = f"{request.get_host()}:"
        msg += f" ({request.user}/{request.user.id})"
        msg += f" caused {code} at {request.get_full_path()}"
        if details:
            Notify.notify_admin_file(msg, msg + '\n' + details)
        else:
            Notify.notify_admin_msg(msg)

    return response

def NotFoundView(request, exception=None):
    return ErrorNotifierView(request, 404, "Not Found")
def PermissionErrorView(request, exception=None):
    return ErrorNotifierView(request, 403, "Permission Denied")
def ServerErrorView(request, exception=None):
    e_type, value, tb = sys.exc_info()
    error_trace=traceback.format_exception(e_type,value,tb)
    return ErrorNotifierView(request,
                             500,
                             "Server Error",
                             ''.join(error_trace))
