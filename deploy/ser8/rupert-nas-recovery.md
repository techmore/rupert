# NAS recovery copy

`rupert-nas-recovery.sh` starts the container's encrypted backup service and copies its database, settings and environment artifacts, checksums and key metadata to the NAS. It verifies the NFS source, encryption header and checksum before atomically publishing a recovery set. It requires an existing encrypted backup configuration and an independently saved recovery kit; it does not create or recover encryption keys.

Configure the host's service environment with `RUPERT_NAS_MOUNT` (the mounted NFS directory), `RUPERT_NAS_SOURCE` (the exact source reported by `findmnt`), `RUPERT_NAS_CONTAINER` (the Incus container name), and `RUPERT_NAS_READER_UID` (the mapped host UID allowed to read the copied artifacts). Create the `rupert-recovery` directory on the mounted share before running. Keep site-specific paths, addresses and any secrets in host configuration rather than the repository.

The repository script is a parameterized version of the host workflow. Run `python3 -m unittest deploy.ser8.tests.test_nas_recovery` for the synthetic copy and wrong-mount tests. Those tests do not verify a real age key, the host's UID mapping, or that a backup can be decrypted and restored; validate those separately on the target system before relying on it. Do not replace a running host job merely by copying this file.
