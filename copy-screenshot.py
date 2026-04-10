#!/usr/bin/env python3
import shutil
import os

source = '/var/folders/2r/knnqkv9d3w3cwcg76htqtcp00000gp/T/cursor/screenshots/Users/sbecker11/workspace-spring/linkage-engine/docs/chord-diagram.png'
dest = '/Users/sbecker11/workspace-spring/linkage-engine/docs/chord-diagram.png'

if os.path.exists(source):
    shutil.copy2(source, dest)
    print(f'File copied successfully to {dest}')
    # Get file size
    size = os.path.getsize(dest)
    print(f'File size: {size} bytes')
    # Get image dimensions
    try:
        from PIL import Image
        img = Image.open(dest)
        print(f'Image dimensions: {img.width} x {img.height} pixels')
    except ImportError:
        print('PIL not available, cannot get dimensions')
else:
    print(f'Source file not found: {source}')
