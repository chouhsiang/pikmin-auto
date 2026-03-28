#!/bin/bash


sudo ps -A | grep pymobiledevice3 | awk '{print $1}' | xargs sudo kill -9

sudo python3 -m pymobiledevice3 remote tunneld -d 

python3 -m uvicorn main:app --reload --host 127.0.0.1 --port 8000
