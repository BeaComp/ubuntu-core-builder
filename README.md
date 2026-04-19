
# 🔐 Authentication and Key Configuration Guide (Ubuntu Core)

To generate custom Ubuntu Core images, it is strictly necessary that the image be signed by a cryptographic key validated by Canonical (Snap Store).

This guide explains how to perform the initial security configuration **inside the Docker container**, ensuring that your passwords are not exposed in the source code.

## ⚠️ Prerequisites
1. The Docker container `ubuntu-core-builder` must be running (use the initialization script):
```bash
docker compose up -d
```

2. You need an active account on **Ubuntu One** (https://login.ubuntu.com).
3. You must have accepted the Developer Terms in the **Snapcraft** dashboard (https://dashboard.snapcraft.io).

---

## 🔑 Extra Prerequisite: SSH Key for Device Access

```bash

Attention: Ubuntu Core does not have password access. The only way to connect to the device via SSH after installation is through an SSH key linked to your Ubuntu One account. If you skip this step, you will not be able to access the device later.
```


Why is this necessary?
Ubuntu Core is an immutable and security-focused operating system. Therefore, it disables password login in SSH by default. During initialization, the system automatically searches for public SSH keys registered in your Ubuntu One account and installs them on the device, allowing only you to connect.

How to configure:

1. Generate an SSH key pair on your machine (if you don't have one yet):

```bash
ssh-keygen -t ed25519 -C "your-email@example.com"
```


This creates two files: ~/.ssh/id_ed25519 (private key, never share) and ~/.ssh/id_ed25519.pub (public key).

3. Copy the content of your public key:
   
```bash
cat ~/.ssh/id_ed25519.pub
```

5. Add the key to your Ubuntu One account:

Go to https://login.ubuntu.com
Go to "SSH Keys" in the side menu
Click on "Add SSH Key" and paste the content copied in the previous step.

4. Connecting to the device after installation:
Once the device has Ubuntu Core installed and is on the same network, connect with:

```bash
ssh <your-ubuntu-one-username>@<device-ip>
```

## 🛠️ Step by Step (Initial Setup)

All operations below should be done **only once** per machine/environment.

### Step 1: Install the dependencies
Start the script that will download the dependencies in the container to generate the image:
```bash
docker exec -it ubuntu-core-builder /workspace/check-dependency.sh
```

### Step 2: Enter the Container
Open your terminal and access the interactive bash of the container with root privileges:
```bash
docker exec -it ubuntu-core-builder bash
```

### Step 3: Configure the Snap Path
Inside the container, ensure that the terminal can find the Snapcraft commands:
```bash
export PATH=$PATH:/snap/bin
```

### Step 4: Login and Generate the Secure Token
To avoid putting passwords in scripts, we will generate a long-lasting access token and save it in the `workspace` folder. To do this, log in to your Ubuntu One account:

* **Note:** The terminal will ask for your email, Ubuntu One password, and the 2-Factor Authentication code (if you have activated it).
```bash
snapcraft login
```

After that, export your secure token:
* **Note:** It is likely that the terminal will ask again for your Ubuntu One email and password.
```bash
snapcraft export-login /workspace/credentials.txt
```

### Step 5: Load the Token in the Current Session
For the next step to work, tell the terminal to use the token you just generated in Step 3:
```bash
export SNAPCRAFT_STORE_CREDENTIALS=$(cat /workspace/credentials.txt)
```

* **Note:** The generated file (`credentials.txt`) is your passport and should never be "committed" to Git.

### Step 6: Create the Local Signing Key
Now, we will create the cryptographic key that will sign your files (`model.json` and `system-user`). Replace `YOUR_KEY_NAME` with a unique name for your project (e.g., `iot-project-key`).
```bash
snapcraft create-key YOUR_KEY_NAME
```
* **Note:** It will ask you to create a **Passphrase** (key password). Write down this password, you will need it in the `.env` file.

### Step 7: Register the Key with Canonical (Cloud)
This is the most critical step. Ubuntu Core requires a "chain of trust" (`--chain`). For this, Canonical needs to know that this key belongs to your account.
```bash
snapcraft register-key YOUR_KEY_NAME
```
* **Success:** If everything goes well, the terminal will respond with *Key successfully registered*.

### Step 8: Discover Your Developer ID
For you to have permission to sign the image, the `model.json` file needs to contain your Canonical developer ID. To find out what yours is, type:
```bash
snapcraft whoami
```
* **Note:** The command will print something like `your-email@example.com (developer-id: YbZ78x...)`. Copy the alphanumeric code inside the parentheses.

### Step 9: Exit the Container
The manual configuration is complete. Type `exit` to return to your real machine's terminal.
```bash
exit
```

---

## 📝 Project Integration

Now that the secure environment has been created, you need to feed the project with this information.

**1. Update the `.env` file:**
In your `.env` file (in the `workspace` folder), put the name of the key you registered and the passphrase you created in Step 6:
```text
KEY_NAME="YOUR_KEY_NAME"
KEY_PASSPHRASE="your_secret_password"
```

**2. Update the `model.json` file:**
Open the `model.json` file and replace the `authority-id` and `brand-id` fields with the code you copied in Step 8:
```json
{
  "type": "model",
  "series": "16",
  "authority-id": "PASTE_YOUR_DEVELOPER_ID_HERE",
  "brand-id": "PASTE_YOUR_DEVELOPER_ID_HERE",
}
...
```

**Done!** The environment is authenticated and the automatic `build-image.sh` script can now be executed.

```bash
docker exec -it ubuntu-core-builder /workspace/build-image.sh
```
