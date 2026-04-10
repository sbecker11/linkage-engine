const fs = require('fs');
const path = require('path');

const source = '/var/folders/2r/knnqkv9d3w3cwcg76htqtcp00000gp/T/cursor/screenshots/Users/sbecker11/workspace-spring/linkage-engine/docs/chord-diagram.png';
const dest = '/Users/sbecker11/workspace-spring/linkage-engine/docs/chord-diagram.png';

try {
  if (fs.existsSync(source)) {
    fs.copyFileSync(source, dest);
    console.log('File copied successfully to', dest);
    const stats = fs.statSync(dest);
    console.log('File size:', stats.size, 'bytes');
    
    // Try to get image dimensions
    const PNG = require('pngjs').PNG;
    const data = fs.readFileSync(dest);
    const png = PNG.sync.read(data);
    console.log('Image dimensions:', png.width, 'x', png.height, 'pixels');
  } else {
    console.log('Source file not found:', source);
  }
} catch (error) {
  console.error('Error:', error.message);
  // Try without pngjs
  try {
    fs.copyFileSync(source, dest);
    console.log('File copied successfully to', dest);
    const stats = fs.statSync(dest);
    console.log('File size:', stats.size, 'bytes');
  } catch (e) {
    console.error('Copy failed:', e.message);
  }
}
