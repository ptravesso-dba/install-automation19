# Oracle Grid DG Automation

These files automate the manual procedure in `instalacao-oraclegrid.txt` for Oracle Grid Infrastructure 19c, ASM/AFD, and Oracle Database 19c.

The same script supports two modes controlled by `IS_STANDBY` in `oracle_grid_dg_vars.conf`:

- `IS_STANDBY="no"`: primary installation, including DBCA, ARCHIVELOG, FORCE LOGGING, and RMAN backup.
- `IS_STANDBY="yes"`: standby preparation only. It installs OS/Grid/ASM/RECO/Oracle DB software and stops before DBCA.

## Files

- `/root/script/install/oracle_grid_dg_vars.conf`: small root-only variables file.
- `/root/script/install/install_oracle_grid_dg.sh`: main installer script.
- `/root/script/install/README_AUTOMATION.md`: this guide.
- `/root/script/install/logs`: timestamped logs.
- `/root/script/install/status`: status files.

## Edit Variables

Review `/root/script/install/oracle_grid_dg_vars.conf` before running the install. The defaults follow the procedure and the validated target VM disk layout:

- `/u01`: `/dev/sdg`, already mounted as `VG00/LVU01` when present.
- `/u02`: `/dev/sdf`, already mounted as `VG01/LVU02` when present.
- ASM DATA: `/dev/sdb /dev/sdc`
- ASM RECO: `/dev/sdd`
- AFD diskstring: `/dev/sd*`

For the standby VM, set:

```bash
IS_STANDBY="yes"
HOSTNAME_FQDN="oracle-dg02.localdomain"
HOSTNAME_SHORT="oracle-dg02"
HOST_ALIAS="dg02"
HOST_IP="192.168.3.66"
PRIMARY_HOST_IP="192.168.3.65"
PRIMARY_HOSTNAME_SHORT="oracle-dg01"
PRIMARY_HOSTNAME_FQDN="oracle-dg01.localdomain"
PRIMARY_HOST_ALIAS="dg01"
```

Oracle Grid and Oracle Database homes remain under `/u01`, exactly as in the source procedure. `/u02` is only prepared and validated for future use.

Keep the variables file protected:

```bash
chmod 600 /root/script/install/oracle_grid_dg_vars.conf
```

## Discovery Mode

Discovery mode is read-only and prints disk, mount, LVM, filesystem, and installer context.

```bash
/root/script/install/install_oracle_grid_dg.sh --discover
```

## Check Mode

Check mode is read-only. It validates the target host, Oracle Linux version, installer zips, packages, hostname/IP context, and disk safety.

```bash
chmod +x /root/script/install/install_oracle_grid_dg.sh
/root/script/install/install_oracle_grid_dg.sh --check
```

The real installation should only be started after the check output is reviewed.

For primary mode, check output shows:

```text
Installation mode: PRIMARY
Target host: 192.168.3.65
DBCA creation: ENABLED
ARCHIVELOG/FORCE LOGGING step: ENABLED
RMAN backup step: ENABLED
```

For standby preparation mode, check output shows:

```text
Installation mode: STANDBY PREPARATION
Target host: 192.168.3.66
DBCA creation: SKIPPED
ARCHIVELOG/FORCE LOGGING local database step: SKIPPED
RMAN backup step: SKIPPED
Stop point: before 1.17.12.1 Criando a instância de Produção
```

## Running with tmux

The real install is long-running and must be started inside `tmux`.

Interactive option:

```bash
tmux new -s oracle_grid_dg_install
/root/script/install/install_oracle_grid_dg.sh --yes
```

Detached one-line option:

```bash
tmux new-session -d -s oracle_grid_dg_install "/root/script/install/install_oracle_grid_dg.sh --yes | tee -a /root/script/install/logs/oracle_grid_dg_install_console.log"
```

Reattach:

```bash
tmux attach -t oracle_grid_dg_install
```

Check sessions:

```bash
tmux ls
```

Follow the latest install log:

```bash
tail -f /root/script/install/logs/oracle_grid_dg_install_*.log
```

Show current automation status without modifying anything:

```bash
/root/script/install/install_oracle_grid_dg.sh --status
```

## Resume Checkpoints

The installer keeps resume checkpoints in:

```bash
/root/script/install/status/oracle_grid_dg_install.checkpoint
```

Adopt the current host state into checkpoints without running installer commands:

```bash
/root/script/install/install_oracle_grid_dg.sh --adopt-current-state
```

Clear only the checkpoint file:

```bash
/root/script/install/install_oracle_grid_dg.sh --clear-checkpoints
```

The status command prints both the human-readable status file and the checkpoint file:

```bash
/root/script/install/install_oracle_grid_dg.sh --status
```

## Standby Completion

When `IS_STANDBY="yes"`, the script stops after Oracle Database software installation and `glogin.sql` creation. It does not run DBCA, local ARCHIVELOG/FORCE LOGGING, or RMAN backup.

Expected final message:

```text
Standby server preparation completed successfully.
The next phase is Data Guard standby creation / RMAN duplicate from the primary database.
```
