import logging
import os
import time

from progressbar import progressbar,ProgressBar

from main.models import *
from main.search import TatorSearch

from elasticsearch.helpers import streaming_bulk

logger = logging.getLogger(__name__)

""" Utility scripts for data management in django-shell """

def clearDataAboutMedia(id):
    """
    Given an id Delete all states, localizations that apply.

    :param id: The id of the media element to purge metadata about.
    """
    #Delete all states by hitting associations which auto delete states
    qs=AssociationType.objects.filter(media__in=[id])
    qs.delete()

    #Delete all localizations
    qs=EntityLocalizationBase.objects.filter(media=id)
    qs.delete()

def makeLocalizationsRelative():
    boxes=EntityLocalizationBox.objects.filter(relativeCoords=False)
    lines=EntityLocalizationLine.objects.filter(relativeCoords=False)
    dots=EntityLocalizationDot.objects.filter(relativeCoords=False)

    for box in boxes:
        media=box.media
        box.height = box.height / media.height
        box.y = box.y / media.height
        box.width = box.width / media.width
        box.x = box.x / media.width
        box.relativeCoords = True
        box.save()

    for line in lines:
        media=line.media
        line.y0 = line.y0 / media.height
        line.y1 = line.y1 / media.height
        line.x0 = line.x0 / media.width
        line.x1 = line.x1 / media.width
        line.relativeCoords = True
        line.save()

    for dot in dots:
        media=dot.media
        dot.y = dot.y / media.height
        dot.x = dot.x / media.width
        dot.relativeCoords = True
        dot.save()

def updateProjectTotals():
    projects=Project.objects.all()
    for project in projects:
        files = EntityMediaBase.objects.filter(project=project)
        if files.count() != project.num_files:
            project.num_files = files.count()
            project.size = 0
            for file in files:
                try:
                    project.size += file.file.size
                    project.size += file.thumbnail.size
                    if isinstance(file, EntityMediaVideo):
                        if file.original:
                            statinfo = os.stat(file.original)
                            project.size = project.size + statinfo.st_size
                        project.size += file.thumbnail_gif.size
                except:
                    pass
            logger.info(f"Updating {project.name}: Num files = {project.num_files}, Size = {project.size}")
            project.save()

def moveCompletedAlgRuns(project_id, from_section, to_section):
    results = AlgorithmResult.objects.filter(
        algorithm__project=project_id,
        media__attributes__tator_user_sections=from_section,
        result=JobResult.FINISHED,
    )
    count = 0
    for result in results:
        for media in result.media.all():
            media.attributes['tator_user_sections'] = to_section
            media.save()
            count += 1
    print(f"Moved {count} files.")

def moveFileToNewProjectFolder(element, fileField, project_number):
    current_path = fileField.path
    current_root = os.path.dirname(current_path)
    if os.path.basename(current_root) == f"{project_number}":
        print(f"Skipping processed file ({current_path})")
        return
    current_fname = os.path.basename(current_path)
    project_base = os.path.join(current_root, f"{project_number}")
    os.makedirs(project_base, exist_ok=True)
    new_path = os.path.join(project_base, current_fname)
    try:
        if not os.path.exists(new_path):
            os.rename(current_path, new_path)
        fileField.name = f"{project_number}/{current_fname}"
        element.save()
    except Exception as e:
        print(f"Unable to move {current_path} to {new_path}")

def movePackagesToProjectDirectories():
    packages = Package.objects.all()
    for package in packages:
        moveFileToNewProjectFolder(package,
                                   package.file,
                                   package.project.id)
def moveAlgoLogsToProjectDirectories():
    algo_results = AlgorithmResult.objects.all().select_related('algorithm__project')
    count = algo_results.count()
    idx = 0
    for algo_result in algo_results:
        idx += 1
        for field in [algo_result.setup_log,
                      algo_result.algorithm_log,
                      algo_result.teardown_log]:
            if field:
                moveFileToNewProjectFolder(algo_result,
                                           field,
                                           algo_result.algorithm.project.id)
        print(f"{idx}/{count}")

    algos = Algorithm.objects.all()
    count = algos.count()
    idx = 0
    for algo in algos:
        idx += 1
        for field in [algo.setup,
                      algo.teardown]:
            if field:
                moveFileToNewProjectFolder(algo,
                                           field,
                                           algo.project.id)
        print(f"{idx}/{count}")

def moveToProjectDirectories(project_number):
    images = EntityMediaImage.objects.filter(project__id=project_number)
    videos = EntityMediaVideo.objects.filter(project__id=project_number)
    idx = 0
    # Process images first
    count = images.count()
    for image in images:
        idx += 1
        moveFileToNewProjectFolder(image, image.thumbnail, project_number)
        moveFileToNewProjectFolder(image, image.file, project_number)
        print(f"Images: {idx}/{count}")

    # Process videos second
    count = videos.count()
    idx = 0
    for video in videos:
        idx += 1
        project_number = video.project.id
        if video.segment_info:
            current_base = os.path.dirname(video.segment_info)
            if os.path.basename(current_base) == f"{project_number}":
                print("Skipping already processed file")
            else:
                current_name = os.path.basename(video.segment_info)
                project_base = os.path.join(current_base, f"{project_number}")
                os.makedirs(project_base, exist_ok=True)
                try:
                    current_path = os.path.join(current_base,current_name)
                    new_path = os.path.join(project_base, current_name)
                    os.rename(current_path, new_path)
                    video.segment_info = os.path.join(project_base, current_name)
                    print(f"Moved {current_base}/{current_name} to {project_base}/{current_name}")
                    video.save()
                except Exception as e:
                    print(f"Unable to move '{current_name}'")
        else:
            #Check for phantom segment
            segment_name = f"{os.path.splitext(video.file.name)[0]}_segments.json"
            current_base = os.path.dirname(video.file.path)
            if os.path.basename(current_base) == f"{project_number}":
                print("Skipping already processed file")
            else:
                project_base = os.path.join(current_base, f"{project_number}")
                segment_path = os.path.join(current_base, segment_name)
                if os.path.exists(segment_path):
                    try:
                        new_path = os.path.join(project_base, segment_name)
                        os.rename(segment_path, new_path)
                        print("Adding phantom segment.")
                        video.segment_info = new_path
                        video.save()
                    except:
                        print(f"Unable to move {segment_name}")
                else:
                    print(f"No segment file exists for {video}")

        moveFileToNewProjectFolder(video, video.thumbnail, project_number)
        moveFileToNewProjectFolder(video, video.thumbnail_gif, project_number)
        moveFileToNewProjectFolder(video, video.file, project_number)

        if video.original:
            current_base = os.path.dirname(video.original)
            if os.path.basename(current_base) == f"{project_number}":
                print("Skipping already processed file")
            else:
                current_name = os.path.basename(video.original)
                project_base = os.path.join(current_base, f"{project_number}")
                os.makedirs(project_base, exist_ok=True)
                new_path = os.path.join(project_base, current_name)
                os.rename(video.original, new_path)
                video.original = new_path
                print(f"Moved {current_base}/{current_name} to {project_base}/{current_name}")
                video.save()



        print(f"Videos: {idx}/{count}")

def waitForMigrations():
    """Sleeps until database objects can be accessed.
    """
    while True:
        try:
            list(Project.objects.all())
            break
        except:
            time.sleep(10)

def buildSearchIndices(project_number, section, mode='index'):
    """ Builds search index for a project.
        section must be one of:
        'index' - create the index for the project if it does not exist
        'mappings' - create mappings for the project if they do not exist
        'media' - create documents for media
        'states' - create documents for states
        'localizations' - create documents for localizations
        'treeleaves' - create documents for treeleaves
    """
    project_name = Project.objects.get(pk=project_number).name
    logger.info(f"Building search indices for project {project_number}: {project_name}")

    if section == 'index':
        # Create indices
        logger.info("Building index...")
        TatorSearch().create_index(project_number)
        logger.info("Build index complete!")
        return

    if section == 'mappings':
        # Create mappings
        logger.info("Building mappings...")
        for attribute_type in progressbar(list(AttributeTypeBase.objects.filter(project=project_number))):
            TatorSearch().create_mapping(attribute_type)
        logger.info("Build mappings complete!")
        return

    class DeferredCall:
        def __init__(self, qs):
            self._qs = qs
        def __call__(self):
            for entity in self._qs.iterator():
                for doc in TatorSearch().build_document(entity, mode):
                    yield doc

    if section == 'media':
        # Create media documents
        logger.info("Building media documents...")
        qs = EntityMediaBase.objects.filter(project=project_number)

    if section == 'localizations':
        # Create localization documents
        logger.info("Building localization documents")
        qs = EntityLocalizationBase.objects.filter(project=project_number)

    if section == 'states':
        # Create state documents
        logger.info("Building state documents...")
        qs = EntityState.objects.filter(project=project_number)

    if section == 'treeleaves':
        # Create treeleaf documents
        logger.info("Building tree leaf documents...")
        qs = TreeLeaf.objects.filter(project=project_number)

    batch_size = 500
    count = 0
    bar = ProgressBar(redirect_stderr=True, redirect_stdout=True)
    dc = DeferredCall(qs)
    total = qs.count()
    bar.start(max_value=total)
    for ok, result in streaming_bulk(TatorSearch().es, dc(),chunk_size=batch_size, raise_on_error=False):
        action, result = result.popitem()
        if not ok:
            print(f"Failed to {action} document! {result}")
        bar.update(min(count, total))
        count += 1
        if count > total:
            print(f"Count exceeds list size by {total - count}")
    bar.finish()

def swapLatLon():
    """ Swaps lat/lon stored in geoposition attributes.
    """
    logger.info("Building entity list...")
    entities = []
    for attribute_type in progressbar(list(AttributeTypeGeoposition.objects.all())):
        entities = list(EntityBase.objects.filter(meta=attribute_type.applies_to))
        for entity in progressbar(entities):
            attr = attribute_type.name
            if attr in entity.attributes:
                entity.attributes[attr] = entity.attributes[attr][::-1]
                entity.save()
    logger.info("Updating entities...")

def makeDefaultVersion(project_number):
    """ Creates a default version for a project and sets all localizations
        and states to that version. Meant for usage on projects that were
        not previously using versions.
    """
    project = Project.objects.get(pk=project_number)
    version = Version.objects.filter(project=project, number=0)
    if version.exists():
        version = version[0]
    else:
        version = make_default_version(project)
    logger.info("Updating localizations...")
    qs = EntityLocalizationBase.objects.filter(project=project)
    qs.update(version=version)
    logger.info("Updating states...")
    qs = EntityState.objects.filter(project=project)
    qs.update(version=version)

def associateExtractions(project, section_names):
    if type(section_names) == str:
        section_names=[section_names]
    for section_name in section_names:
        videos = EntityMediaVideo.objects.filter(attributes__contains={"tator_user_sections": section_name}).filter(project=project)
        events = FrameAssociation.objects.filter(media__in=videos)
        for video in progressbar(videos):
            events = FrameAssociation.objects.filter(media__in=[video.id])
            for event in events:
                extracted_name = f"{video.id}_{video.name}_{event.frame}.png"
                image = EntityMediaImage.objects.filter(project=project,
                                                    name=extracted_name)
                if image.count() == 1:
                    event.extracted = image[0]
                    event.save()
                else:
                    print(f"Couldn't find {extracted_name}")
