# Hello World - Black Pill F411CE with USB CDC Console

This is a copy of the Zephyr Hello World example configured for the WeAct Black Pill F411CE board with USB CDC ACM serial console.

## Hardware
- **Board**: WeAct Black Pill F411CE (STM32F411CEU6)
- **USB**: USB-C connector (acts as USB CDC serial device)

## Building

```bash
cd /workspace/apps/hello_world_blackpill
west build -p auto -b blackpill_f411ce
```

## Flashing

Flash the firmware to your Black Pill using one of these methods:

### Using STLink (if you have one):
```bash
west flash
```

### Using DFU mode (built-in USB bootloader):
1. Connect your Black Pill via USB-C
2. Hold BOOT0 button, press and release RESET, release BOOT0
3. Flash using dfu-util:
```bash
dfu-util -a 0 -s 0x08000000:leave -D build/zephyr/zephyr.bin
```

## Using the USB Console

After flashing and resetting the board:

1. The Black Pill will enumerate as a USB CDC device
2. On Linux, it will appear as `/dev/ttyACM0` (or similar)
3. Connect with any serial terminal:
   ```bash
   screen /dev/ttyACM0 115200
   # or
   minicom -D /dev/ttyACM0
   # or
   picocom /dev/ttyACM0
   ```

4. You should see: `Hello World! blackpill_f411ce/stm32f411xe`

## Configuration

The USB CDC configuration is in `prj.conf`:
- USB Device Stack enabled
- USB CDC ACM class enabled  
- Console redirected to USB

## Memory Usage

```
FLASH: ~23 KB / 512 KB (4.4%)
RAM:   ~7.7 KB / 128 KB (5.9%)
```

## Modifying the Code

Edit `src/main.c` to customize your application, then rebuild with `west build`.
