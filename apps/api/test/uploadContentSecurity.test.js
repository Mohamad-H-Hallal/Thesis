const AdmZip = require('adm-zip');
const {
  inspectArchive,
  inspectImportContent,
} = require('../src/services/uploadContentSecurity.service');

const originalEnv = {
  ARCHIVE_MAX_ENTRIES: process.env.ARCHIVE_MAX_ENTRIES,
  ARCHIVE_MAX_EXPANDED_BYTES: process.env.ARCHIVE_MAX_EXPANDED_BYTES,
  ARCHIVE_MAX_ENTRY_BYTES: process.env.ARCHIVE_MAX_ENTRY_BYTES,
  ARCHIVE_MAX_COMPRESSION_RATIO: process.env.ARCHIVE_MAX_COMPRESSION_RATIO,
};

const restoreEnv = () => {
  for (const [key, value] of Object.entries(originalEnv)) {
    if (value === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
};

const zipBuffer = (entries) => {
  const zip = new AdmZip();
  for (const [name, value] of Object.entries(entries)) {
    zip.addFile(name, Buffer.isBuffer(value) ? value : Buffer.from(value));
  }
  return zip.toBuffer();
};

const traversalZipBuffer = () => {
  const safeName = Buffer.from('aa/escape.shp');
  const unsafeName = Buffer.from('../escape.shp');
  const buffer = zipBuffer({ 'aa/escape.shp': 'x' });
  let offset = 0;
  while ((offset = buffer.indexOf(safeName, offset)) >= 0) {
    unsafeName.copy(buffer, offset);
    offset += unsafeName.length;
  }
  return buffer;
};

const xlsxBuffer = () =>
  zipBuffer({
    '[Content_Types].xml': '<Types/>',
    '_rels/.rels': '<Relationships/>',
    'xl/workbook.xml': '<workbook/>',
    'xl/_rels/workbook.xml.rels': '<Relationships/>',
    'xl/worksheets/sheet1.xml': '<worksheet/>',
  });

describe('upload content security', () => {
  afterEach(restoreEnv);

  test('identifies allowed text and archive formats from bytes', () => {
    expect(
      inspectImportContent(Buffer.from('  {"type":"FeatureCollection","features":[]}'), 'geojson'),
    ).toEqual({ detectedType: 'json' });
    expect(inspectImportContent(Buffer.from('<?xml version="1.0"?><kml></kml>'), 'kml')).toEqual({
      detectedType: 'xml',
    });
    expect(inspectImportContent(Buffer.from('name,latitude,longitude\nA,1,2'), 'csv')).toEqual({
      detectedType: 'text',
    });
    expect(inspectImportContent(xlsxBuffer(), 'xlsx')).toMatchObject({
      detectedType: 'zip',
      archive: { entryCount: 5 },
    });
  });

  test('rejects binary or disguised content before parsing', () => {
    expect(() => inspectImportContent(Buffer.from('not a zip'), 'shapefile_zip')).toThrow(
      'archive signature',
    );
    expect(() => inspectImportContent(Buffer.from('<html></html>'), 'geojson')).toThrow(
      'GeoJSON signature',
    );
    expect(() => inspectImportContent(Buffer.from('plain text'), 'kml')).toThrow('KML signature');
    expect(() => inspectImportContent(Buffer.from([0xff, 0xfe, 0x00]), 'csv')).toThrow(
      'binary data',
    );
  });

  test('rejects traversal, nested archives, and incomplete office archives', () => {
    expect(() => inspectArchive(traversalZipBuffer(), 'shapefile_zip')).toThrow(
      'unsafe entry path',
    );
    expect(() => inspectArchive(zipBuffer({ 'nested/payload.zip': 'x' }), 'shapefile_zip')).toThrow(
      'Nested archives',
    );
    expect(() => inspectArchive(zipBuffer({ 'xl/workbook.xml': '<workbook/>' }), 'xlsx')).toThrow(
      'required workbook structure',
    );
    expect(() =>
      inspectArchive(
        zipBuffer({
          '[Content_Types].xml': '<Types/>',
          'xl/workbook.xml': '<workbook/>',
          'xl/_rels/workbook.xml.rels': '<Relationships/>',
          'xl/vbaProject.bin': 'macro',
        }),
        'xlsx',
      ),
    ).toThrow('Macro-enabled');
  });

  test('enforces archive entry, expanded-size, and compression-ratio ceilings', () => {
    process.env.ARCHIVE_MAX_ENTRIES = '1';
    expect(() =>
      inspectArchive(zipBuffer({ 'a.txt': 'a', 'b.txt': 'b' }), 'shapefile_zip'),
    ).toThrow('unsafe number of entries');

    process.env.ARCHIVE_MAX_ENTRIES = '10';
    process.env.ARCHIVE_MAX_ENTRY_BYTES = '10';
    process.env.ARCHIVE_MAX_EXPANDED_BYTES = '20';
    expect(() =>
      inspectArchive(zipBuffer({ 'large.txt': Buffer.alloc(11, 1) }), 'shapefile_zip'),
    ).toThrow('oversized entry');

    process.env.ARCHIVE_MAX_ENTRY_BYTES = '2097152';
    process.env.ARCHIVE_MAX_EXPANDED_BYTES = '2097152';
    process.env.ARCHIVE_MAX_COMPRESSION_RATIO = '2';
    expect(() =>
      inspectArchive(zipBuffer({ 'repeated.txt': Buffer.alloc(1024 * 1024, 65) }), 'shapefile_zip'),
    ).toThrow('compression ratio');
  });
});
