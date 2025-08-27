# 🔐 WIFI SYSTEM – SSH Bypass Guide for Beginners

> ⚠️ **WARNING**: This guide assumes you have **legitimate access** to the device.  
> Using it for unauthorized access is **illegal**.

> 💡 **Note:**  
> The same principle applies to most **PisoWiFi systems**.  
> Another method is by editing `cmdline.txt` and appending `init=/bin/sh` at the end of the line to reset the password manually.  
> However, this typically works only on Raspberry Pi devices, and some systems have integrity checks that prevent booting if the password is modified.

---

## 🧰 Requirements

- A **Linux OS** (Ubuntu, Debian, etc.)
- The **WIFISYSTEM SD card / SSD / HDD** (e.g., from a Raspberry Pi or Orange Pi or PC)
- Your **own SSH public key**
- Basic familiarity with the **terminal**
- **sudo/root access** on your Linux machine

---

## ✅ Step-by-Step Instructions

### 1. Insert the SD Card

1. Boot into any Linux OS.
2. Insert your Wifi5Soft SD card.
3. Wait a few seconds — the partitions should auto-mount.

---

### 2. Locate the Partitions

You will usually see **two partitions**:

- One labeled **`boot`**
- One with no label — this is the **rootfs (system)** partition.

---

### 3. Open a Terminal and Mount the Partition

Navigate into the second partition (not `boot`):

```bash
cd /media/$USER/<partition-name>
```

> You can check with `ls /media/$USER/` if you're unsure of the exact path.

Example:

```bash
cd /media/$USER/sdc2
```

### 4: Navigate to Dropbear Folder

```bash
cd etc/dropbear
```

### 5: Create the `authorized_keys` File

1. Copy one of the existing keys (just to create a file with correct permissions):

```bash
cp dropbear_rsa_host_key authorized_keys
```

2. Overwrite the new file with your actual public key:

```bash
echo 'ssh-rsa AAAAB3...your-key... user@machine' > authorized_keys
```

### 6: Modify Dropbear Config

1. Go up one directory and enter the `config` folder:

```bash
cd ../config
```

2. Edit the dropbear config file:

```bash
sudo nano dropbear
```

3. Change these lines:

```sh
option PasswordAuth 'on'
option RootPasswordAuth 'on'
```

**To:**

```sh
option PasswordAuth 'off'
option RootPasswordAuth 'off'
```

4. (Optional) Allow SSH from all interfaces by commenting out:

```sh
#       option Interface 'lan'
```

5. Save and exit (CTRL+O, then CTRL+X in nano).

### Step 7: Safely Remove the SD Card

- Eject both partitions using your file manager.
- Physically remove the SD card.

## 🚀 You're Done!

Reinsert the SD card into your **Wifi5Soft device**, power it on, and log in via SSH:

```bash
ssh root@<device-ip>
```

## 🧠 Troubleshooting

- Permission denied? Check if the key is correct.
- Still asks for password? Recheck the config file.
- Wrong partition? Verify your path under `/media/$USER/`.
