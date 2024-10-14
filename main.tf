locals {
  services = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudbuild.googleapis.com",
  ])
  quarantine_registry_url = "${google_artifact_registry_repository.quarantine.location}-docker.pkg.dev/${google_artifact_registry_repository.quarantine.project}/${google_artifact_registry_repository.quarantine.name}"
  release_registry_url    = "${google_artifact_registry_repository.release.location}-docker.pkg.dev/${google_artifact_registry_repository.release.project}/${google_artifact_registry_repository.release.name}"
}

// GCP Services

resource "google_project_service" "api" {
  project  = var.project_id
  for_each = local.services
  service  = each.key
}

// Artifact Registries

resource "google_artifact_registry_repository" "release" {
  project       = var.project_id
  location      = var.location
  repository_id = "release"
  format        = "DOCKER"
  description   = "Release repository for validated Docker images"

  depends_on = [google_project_service.api]
}

resource "google_artifact_registry_repository" "quarantine" {
  project       = var.project_id
  location      = var.location
  repository_id = "quarantine"
  format        = "DOCKER"
  description   = "Quarantine repository for new Docker images"

  depends_on = [google_project_service.api]
}

// Service Account

resource "google_service_account" "quarantine_trigger" {
  project    = var.project_id
  account_id = "quarantine-trigger"
}

// GCS bucket

resource "google_storage_bucket" "quarantine_trigger_logs" {
  project                     = var.project_id
  name                        = "quarantine_trigger_logs"
  location                    = var.location
  force_destroy               = true
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true
}

// Pub/Sub topic

resource "google_pubsub_topic" "notifications" {
  project = var.project_id
  name    = "gcr"

  depends_on = [google_project_service.api]
}

// IAM

resource "google_artifact_registry_repository_iam_member" "quarantine_pusher" {
  for_each   = var.quarantine_pusher
  project    = google_artifact_registry_repository.quarantine.project
  location   = google_artifact_registry_repository.quarantine.location
  repository = google_artifact_registry_repository.quarantine.name
  role       = "roles/artifactregistry.writer"
  member     = each.key
}

resource "google_artifact_registry_repository_iam_member" "quarantine_trigger" {
  project    = google_artifact_registry_repository.quarantine.project
  location   = google_artifact_registry_repository.quarantine.location
  repository = google_artifact_registry_repository.quarantine.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.quarantine_trigger.member
}

resource "google_artifact_registry_repository_iam_member" "quarantine_mover" {
  project    = google_artifact_registry_repository.release.project
  location   = google_artifact_registry_repository.release.location
  repository = google_artifact_registry_repository.release.name
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.quarantine_trigger.member
}

resource "google_project_iam_member" "quarantine_trigger_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.quarantine_trigger.member
}

resource "google_storage_bucket_iam_member" "quarantine_trigger" {
  bucket = google_storage_bucket.quarantine_trigger_logs.name
  role   = "roles/storage.admin" // Todo: check why roles/storage.objectCreator is not enough. Might need roles/storage.legacyBucketReader
  member = google_service_account.quarantine_trigger.member
}

// Cloud Build trigger

resource "google_cloudbuild_trigger" "quarantine_trigger" {
  project         = var.project_id
  location        = var.location
  name            = "quarantine-trigger"
  description     = "Triggers a ClamAV scan of the newly pushed image in quarantine"
  filter          = "_QUARANTINE_IMAGE_TAG.matches('^${local.quarantine_registry_url}/+?') && _ACTION == 'INSERT'"
  service_account = google_service_account.quarantine_trigger.id

  pubsub_config {
    topic = google_pubsub_topic.notifications.id
  }

  build {
    step {
      name = "gcr.io/cloud-builders/docker"
      args = ["pull", "$_QUARANTINE_IMAGE_TAG"]
    }
    step {
      name = "gcr.io/cloud-builders/docker"
      args = ["save", "$_QUARANTINE_IMAGE_TAG", "-o", "/workspace/$BUILD_ID.tar"]
    }
    // Todo: do we really need to extract the tarball? ClamAV can scan archives.
    step {
      name = "bash"
      args = ["tar", "xf", "/workspace/$BUILD_ID.tar"]
    }
    step {
      name = "bash"
      args = ["rm", "/workspace/$BUILD_ID.tar"]
    }
    step {
      name = "clamav/clamav"
      args = ["clamconf", "-n"]
    }
    step {
      name = "clamav/clamav"
      args = ["clamscan", "-r", "--scan-archive=yes", "/workspace"]
    }
    step {
      name = "gcr.io/cloud-builders/docker"
      args = ["tag", "$_QUARANTINE_IMAGE_TAG", "$_RELEASE_IMAGE_TAG"]
    }
    step {
      name = "gcr.io/cloud-builders/docker"
      args = ["push", "$_RELEASE_IMAGE_TAG"]
    }
    logs_bucket = google_storage_bucket.quarantine_trigger_logs.id
  }

  substitutions = {
    _ACTION               = "$(body.message.data.action)"
    _QUARANTINE_IMAGE_TAG = "$(body.message.data.tag)"
    _RELEASE_IMAGE_TAG    = "${local.release_registry_url}/$${_QUARANTINE_IMAGE_TAG##*/}"
  }

  depends_on = [google_project_service.api]
}
