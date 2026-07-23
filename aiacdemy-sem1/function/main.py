import functions_framework
from google.cloud import run_v2, resourcemanager_v3
from google.iam.v1 import iam_policy_pb2
from google.protobuf.field_mask_pb2 import FieldMask


@functions_framework.cloud_event
def auto_grant(cloud_event):
    """
    Triggered by Eventarc on Cloud Run audit log events.
    On any deploy — create or redeploy, via the v1 or v2 API — grants the creator
    run.developer on their service, sets public access (allUsers → run.invoker),
    and stamps an owner label. Handling redeploys (and both API versions) makes
    isolation self-healing and version-agnostic: every deploy from any gcloud
    client re-applies the creator's grants, so a service that ever lost its
    bindings is fixed on the next deploy without any manual admin action.
    """
    data = cloud_event.data
    proto = data.get("protoPayload", {})

    # Act on service create and redeploy, covering BOTH Cloud Run API versions:
    #   v1: CreateService (new)   / ReplaceService (redeploy)
    #   v2: CreateService (new)   / UpdateService  (redeploy)
    # gcloud picks v1 or v2 depending on its version, so we must match all of
    # them or newer clients (v2) are silently missed.
    method = proto.get("methodName", "")
    if not any(m in method for m in ("CreateService", "ReplaceService", "UpdateService")):
        return

    creator = proto.get("authenticationInfo", {}).get("principalEmail", "")
    resource = proto.get("resourceName", "")

    if not creator or not resource:
        print("Missing creator or resource name in audit log — skipping.")
        return

    # Loop guard: skip events initiated by any service account — most importantly
    # this function's own label-stamp, which emits v2 UpdateService (the same
    # method we now listen for). A human deploy is never a service account, so
    # this both breaks the self-trigger loop and avoids granting to SAs.
    if creator.endswith(".gserviceaccount.com"):
        print(f"Skipping service-account event ({method}) by {creator}")
        return

    # Audit log gives v1 format: namespaces/{project}/services/{name}
    # run_v2 client requires v2 format: projects/{project}/locations/{region}/services/{name}
    if resource.startswith("namespaces/"):
        parts = resource.split("/")
        project = parts[1]
        service = parts[3]
        location = data.get("resource", {}).get("labels", {}).get("location", "us-central1")
        resource = f"projects/{project}/locations/{location}/services/{service}"
    else:
        # v2 format already: projects/{project}/locations/{region}/services/{name}
        project = resource.split("/")[1]

    print(f"{method.rsplit('.', 1)[-1]} detected: creator={creator} resource={resource}")

    client = run_v2.ServicesClient()

    # ── Grant service-level IAM ───────────────────────────────────────────────
    policy = client.get_iam_policy(
        request=iam_policy_pb2.GetIamPolicyRequest(resource=resource)
    )

    # Creator can redeploy / update / delete their own service
    _ensure_member(policy, "roles/run.developer", f"user:{creator}")
    # Public browser access (ttyd basic auth is the actual gate)
    _ensure_member(policy, "roles/run.invoker", "allUsers")

    client.set_iam_policy(
        request=iam_policy_pb2.SetIamPolicyRequest(resource=resource, policy=policy)
    )
    print(f"IAM updated — run.developer → {creator}, run.invoker → allUsers")

    # ── Grant run.services.list at project level so creator can see their
    #    service in the Cloud Run console (list is always project-wide in GCP)
    _grant_list_permission(project, creator)

    # ── Stamp owner label for billing attribution ─────────────────────────
    _stamp_owner_label(client, resource, creator)


def _ensure_member(policy, role, member):
    for binding in policy.bindings:
        if binding.role == role:
            if member not in binding.members:
                binding.members.append(member)
            return
    policy.bindings.add(role=role, members=[member])


def _grant_list_permission(project, creator):
    """Grant the groupViewer role (run.services.list only) at project level.

    This is the minimum needed for the creator to see their service in the
    Cloud Run console list. GCP has no per-service list scoping — list is
    always project-wide, so all deployers can see each other's service names
    but cannot see details or env vars (those require run.services.get).
    """
    try:
        crm = resourcemanager_v3.ProjectsClient()
        resource = f"projects/{project}"
        policy = crm.get_iam_policy(request={"resource": resource})
        list_role = f"projects/{project}/roles/groupViewer"
        _ensure_member(policy, list_role, f"user:{creator}")
        crm.set_iam_policy(request={"resource": resource, "policy": policy})
        print(f"groupViewer (run.services.list) granted at project level to {creator}")
    except Exception as e:
        print(f"Warning: could not grant list permission: {e}")


def _stamp_owner_label(client, resource, creator):
    try:
        svc = client.get_service(name=resource)
        # Label values cannot contain @ or . — sanitize
        owner_val = creator.replace("@", "-at-").replace(".", "-")[:63]
        labels = dict(svc.labels)
        if labels.get("owner") == owner_val:
            return
        labels["owner"] = owner_val
        client.update_service(
            request=run_v2.UpdateServiceRequest(
                service=run_v2.Service(name=resource, labels=labels),
                update_mask=FieldMask(paths=["labels"]),
            )
        )
        print(f"Owner label set: {owner_val}")
    except Exception as e:
        print(f"Warning: could not set owner label: {e}")