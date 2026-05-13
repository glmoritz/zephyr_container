import serial
import sys

# 1. Initialize the serial object WITHOUT a port string. 
# This prevents it from opening immediately and toggling the pins.
ser = serial.Serial()
ser.port = '/dev/ttyACM0'
ser.baudrate = 115200

# 2. Explicitly disable DTR and RTS to prevent the ESP32 from resetting
ser.dtr = False
ser.rts = False

try:
    # 3. Open the port silently
    ser.open()
    print("Listening to /dev/ttyACM0 silently (No Reset)...")
    print("Press Ctrl+C to exit.\n" + "-"*40)
    
    while True:
        # Read available bytes and write them to the console
        data = ser.read(ser.in_waiting or 1)
        if data:
            sys.stdout.write(data.decode('utf-8', errors='replace'))
            sys.stdout.flush()
            
except serial.SerialException as e:
    print(f"\nSerial Error: {e}")
    print("Tip: You might need 'sudo' or to add your user to the 'dialout' group.")
except KeyboardInterrupt:
    print("\nExiting monitor...")
finally:
    if ser.is_open:
        ser.close()
