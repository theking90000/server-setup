# Encrypted secrets

This directory contains only JSON values encrypted with SOPS. The
`sops.secrets` declarations, runtime paths, owners, and permissions remain in
the public or private module that consumes each secret.

```sh
init-project             # create missing files and list external fields
sops secrets/acme.json   # edit without leaving a plaintext copy in the repository
update-sops-keys         # update recipients for all JSON files
check-project            # reject CHANGEME values, then evaluate Nix and Colmena
```

`init-project` never replaces an existing file. Commit `.sops.yaml` and the
re-encrypted JSON files together after any recipient change.

Complete guide:
https://github.com/theking90000/server-setup/blob/main/docs/SETUP-GUIDE.md
