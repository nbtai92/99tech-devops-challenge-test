# Problem 2: Diagnose Me Doctor

>**Situation:** An Ubuntu 24.04 VM with 64 GB of storage is stuck at 99% disk usage. It only runs NGINX as a load balancer, so if this box goes down, every service behind it goes down too.

## My short answer

Since the VM only runs NGINX, I'd bet the disk is being filled by NGINX itself. My first suspects are:

- logs that aren't rotating,
- log files that were deleted but are still held open by NGINX,
- a proxy cache with no size limit.

My plan is to:

1. check if users are already affected;
2. free some space safely;
3. find what is actually using the disk;
4. fix the root cause and add alerts so it doesn't happen again.

## Why I care about this one

I've had this happen in production. Our application started returning HTTP 500 when users saved new data. I checked the server logs and found the disk was full, so every write was failing. Restarting the server brought things back.

Looking back, the fact that a restart freed the space tells me it was most likely deleted files still held open by a process. Linux only releases that space when the process closes the file. My main takeaways:

- A full disk usually shows up first as **user errors on writes**, not as a disk alert.
- **A restart is a workaround, not a fix.** The disk will fill up again.
- **Collect evidence before restarting.** Running `df` vs `du` and `lsof +L1` takes a few seconds. I didn't do it back then, so I never confirmed the real cause.

## How I'd troubleshoot

I use two simple methods:

- **RED** (Rate, Errors, Duration) looks at the service from the user's side. Is traffic still flowing? Are there 5xx errors? Is latency going up?
- **USE** (Utilization, Saturation, Errors) looks at each resource on the VM. How full is it? Is it getting worse? Is it throwing errors?

RED tells me **how bad** it is. USE tells me **where** the problem is.

### Step 1: Is anyone affected? (RED)

```bash
sudo journalctl -u nginx --since "1 hour ago"
sudo grep -i "no space left" /var/log/nginx/error.log
sudo awk '$9 ~ /^5/' /var/log/nginx/access.log | wc -l    # count 5xx
```

- **No errors yet:** It's urgent but not an outage, so I take my time and avoid risky actions.
- **Errors are showing up:** Users are hurting. I free space first, then investigate.

When the disk hits 100%, NGINX:

- can't write logs;
- fails requests and responses that are too big for memory buffers (users get 500/502);
- can't reload its config or renew certificates.

### Step 2: Buy time safely

- Grow the disk online if it's a cloud volume (resize, then `growpart` + `resize2fs`). This is the safest option because nothing gets deleted.
- `sudo journalctl --vacuum-size=500M` and `sudo apt-get clean`.
- Compress old rotated logs.
- If an active log is huge, run `truncate -s 0` on it. **Never `rm` a log NGINX is writing to.** The space won't come back, which is exactly the trap I fell into before.

### Step 3: Find the cause (USE + drill-down)

```bash
df -h; df -i                                        # space and inodes
sudo du -xh --max-depth=1 / | sort -h | tail        # biggest folders
sudo du -sh /var/log/nginx /var/cache/nginx /var/lib/nginx
sudo lsof -nP +L1                                    # deleted files still open
lsblk; sudo vgs                                      # is all 64 GB even used?
sudo logrotate -d /etc/logrotate.d/nginx             # is rotation working?
```

The quickest clue is comparing `df` and `du`. If `df` says the disk is full but `du` can't find the files, the space is held by deleted-but-open files.

I'd also glance at CPU, memory and disk I/O (`top`, `free -h`, `iostat -x`) to make sure nothing else is going on.

## Likely causes and fixes

| Cause | How I'd spot it | Fix | Prevent |
|---|---|---|---|
| **Logs not rotating** | `/var/log/nginx` is huge | Clean old logs, fix logrotate | Daily rotation with `maxsize`, ship logs to CloudWatch |
| **Deleted logs still open** | `df` full but `du` small; `lsof +L1` shows nginx | `nginx -s reopen`, no downtime | Truncate instead of `rm`, fix `postrotate` |
| **Proxy cache too big** | `/var/cache/nginx` is huge | Set `max_size` in `proxy_cache_path`, reload | Put cache on its own volume |
| **Temp buffer files** | `/var/lib/nginx/` is huge | Clean old temp files, tune buffer and body size limits | Limits + separate volume |
| **Debug logging left on** | `error.log` grows very fast | Set level back to `warn` | Keep config in Git with review |
| **OS leftovers** (journal, apt cache, old kernels) | `journalctl --disk-usage`, `du /var/cache/apt` | Vacuum the journal, `apt autoremove` | Set `SystemMaxUse` for journald |
| **Disk not fully allocated** | `lsblk` shows 64 GB but root is smaller | `lvextend -r -l +100%FREE` | Check disk layout when provisioning |

### Why "consistently 99%" is interesting

The usage sits at 99% instead of climbing to 100%, so something is probably capping it. Possible explanations:

- the cache `max_size` is set too close to the disk size;
- logrotate is barely keeping up;
- the filesystem is smaller than 64 GB.

The system might be "working as configured", just configured badly. One traffic spike would push it over the edge.

## Preventing it next time

**Alerts.** On AWS, the catch is that **EC2 doesn't report disk usage by default**. I'd:

- install the **CloudWatch Agent** to get `disk_used_percent` and free inodes, and ship the NGINX logs;
- create **CloudWatch Alarms** at 80% (warning) and 90% (page), sent to Slack/email via **SNS**;
- add a **log metric filter** on `No space left on device` and 5xx errors.

I wouldn't rely only on log-based alarms. When the disk is full, NGINX may not be able to write the error that should trigger them, so the disk % alarm is the main one.

**Setup:**

- Put logs and cache on separate volumes so they can't fill the root disk.
- Keep only a few days of logs locally; the rest lives in CloudWatch.
- Run two NGINX nodes so one can be drained without an outage.

**Process:** Write a short runbook from these steps and do a blameless postmortem after the incident.

---

*Note: I used AI to help structure and polish this write-up. The troubleshooting approach, decisions and the production experience are my own.*
