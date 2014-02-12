/*
 * acorn2svg - a tool to convert .acorn documents to SVG images
 *
 * Written by Wim Lewis <wiml@omnigroup.com>
 * Copyright 2014 by Omni Development, Inc.
 *
 * Omni Source License 2007
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use, copy,
 * modify, merge, publish, distribute, sublicense, and/or sell copies
 * of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 *   Any original copyright notices and this permission notice shall be
 *   included in all copies or substantial portions of the Software.
 * 
 *   THE SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND,
 *   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 *   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 *   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 *   BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
 *   ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 *   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *   SOFTWARE.
 *
 */

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#import <AppKit/NSColor.h>
#import <AppKit/NSColorSpace.h>
#import <AppKit/NSBezierPath.h>

#import <AppKit/NSAttributedString.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSFontDescriptor.h>
#import <AppKit/NSTextStorage.h>
#import <AppKit/NSTextContainer.h>
#import <AppKit/NSLayoutManager.h>

#include <err.h>

#import "acorn2svg.h"


/* Globals used by WrittenImage */
NSMutableDictionary *imageCache = nil;
CFURLRef imageTmpDir = NULL;
NSMutableArray *usedImages = nil;

/* Globals used by SVG shadow generation */
CFMutableDictionaryRef shadowCache = NULL;
unsigned int graphicRefSequence = 0;

/* Globals used by font output */
NSMutableDictionary *fontSpecCache = nil;

/* SQLite functions */
int selectAttribute(sqlite3 *dbh, NSData *layer, const char *attname, void (^)(sqlite3_stmt *, int));
CFDataRef copyBlobValue(sqlite3_stmt *sth, int column);
CFStringRef copyStringValue(sqlite3_stmt *sth, int column);
static int checkApplicationID(void *, int, char **, char **);
AcornLayer *copyLayerTree(sqlite3 *dbh);

/* Image output/recoding functions */
NSXMLElement *createImageElementFromData(NSString *uti, CFDataRef layerData, NSString *nameHint);

/* SVG Generation */
void generateSVGForShape(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent);
void generateSVGForRectangle(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent);
void generateSVGForTextArea(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent);
void generateSVGForArrow(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent);
void generateSVGForLine(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent);
void generateSVGForPathGraphic(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent);
void generateSVGForShadow(NSDictionary *obj, NSXMLElement *parent, NSXMLElement *element);
static void generateSVGShadowFilter(const void *, const void *, void *);
static void generateSVGFontFace(const void *, const void *, void *); /* (NSFont *font, NSDictionary *fontAttributes, NSXMLElement *defs) */

void applyPaint(NSXMLElement *elt, NSString *attr, NSString *alpha, NSData *encodedColor);
void applyPaintForColor(NSXMLElement *elt, NSString *attr, NSString *alpha, NSColor *color);
void applyLineJoin(NSXMLElement *elt, NSString *attr, NSObject *encodedJoin);
void applyFillStroke(NSXMLElement *elt, BOOL hasFill, BOOL hasStroke, NSDictionary *obj);
void applyFontAttributes(NSXMLElement *span, NSFont *spanFont);
NSString *filterNameForShadow(NSDictionary *obj);
NSString *svgOpsFromPath(NSBezierPath *p, const NSRect *frame);
NSDictionary *computeAttributesForFont(NSFont *spanFont);

/* Private declaration */
@interface NSFont (AppleHatesTypographers)
- (CTFontRef)ctFontRef;
@end

int main(int argc, char * const * argv)
{
    int rv;
    const char *acorn_filename = argv[1];
    sqlite3 *dbh;
    
    rv = sqlite3_open_v2(acorn_filename, &dbh, SQLITE_OPEN_READONLY, NULL);
    switch(rv) {
        case SQLITE_OK:
            break;
        case SQLITE_NOTADB:
            errx(1, "%s: not a sqlite3 db, and therefore not an Acorn file", acorn_filename);
            break;
        case SQLITE_CANTOPEN:
        case SQLITE_IOERR:
            err(1, "%s: cannot open", acorn_filename);
            break;
        default:
            /* We could use sqlite3_errstr() to give a useful error message, except that Mavericks' sqlite3 is still too old to have that function. */
            errx(1, "%s: cannot open: sqlite3 error #%d", acorn_filename, rv);
            break;
    }
    sqlite3_extended_result_codes(dbh, 1);
    
    /* Check file magic (SQLite application_id) */
    if (sqlite3_libversion_number() >= 3007017) {
        int app_id_ok = 0;
        char *msg;
        rv = sqlite3_exec(dbh, "PRAGMA application_id", checkApplicationID, &app_id_ok, &msg);
        if (msg)
            warnx("%s", msg);
        if (rv || !app_id_ok)
            errx(2, "%s: does not look like an Acorn file", acorn_filename);
    }

    /* Check file version */
    {
        __block int fileVersion;
        
        int count = selectAttribute(dbh, NULL, "acorn.fileVersion", ^(sqlite3_stmt *sth, int iCol){
            fileVersion = sqlite3_column_int(sth, iCol);
        });
        if (count != 1 || fileVersion != 4) {
            errx(1, "%s: unexpected or missing acorn.fileVersion", acorn_filename);
        }
    }
    
    /* Organize the layers in the acorn file into a tree */
    AcornLayer *doc = copyLayerTree(dbh);
    [doc prettyPrint:0];
    
    imageCache = [[NSMutableDictionary alloc] init];
    imageTmpDir = CFURLCreateWithFileSystemPath(NULL, CFSTR("/tmp/images"), kCFURLPOSIXPathStyle, true);
    usedImages = [[NSMutableArray alloc] init];
    shadowCache = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    fontSpecCache = [[NSMutableDictionary alloc] init];
    graphicRefSequence = 0;
    
    /* Generate SVG of the layer tree */
    {
        NSXMLElement *svgElt = [[NSXMLElement alloc] initWithName:@"svg" URI:kSVGNamespace];
        NSXMLDocument *svgDoc = [[NSXMLDocument alloc] initWithRootElement:svgElt];
        
        [svgDoc setDocumentContentKind:NSXMLDocumentXMLKind];
        [svgDoc setCharacterEncoding:@"UTF-8"];
        [svgDoc setVersion:@"1.0"];
        
        [svgElt addNamespace:[NSXMLNode namespaceWithName:@"" stringValue:kSVGNamespace]];
        [svgElt addNamespace:[NSXMLNode namespaceWithName:@"xlink" stringValue:kXLINKNamespace]];
        
        __block CGFloat frameHeight = 0;
        
        setStringAttribute(svgElt, @"version", @"1.0");
        /* TODO: read and use the dpi attribute */
        selectAttribute(dbh, NULL, "imageSize", ^(sqlite3_stmt *sth, int column){
            CFStringRef frameValue = copyStringValue(sth, column);
            NSSize imageSize = NSSizeFromString((__bridge_transfer NSString *)frameValue);
            if (imageSize.width > 0)
                setFloatAttributeSuffixed(svgElt, @"width", imageSize.width, @"pt");
            if (imageSize.height > 0) {
                setFloatAttributeSuffixed(svgElt, @"height", imageSize.width, @"pt");
                frameHeight = imageSize.height;
            }
        });
        
        [doc addSVGToElement:svgElt height:frameHeight dbh:dbh];
        
        NSXMLElement *defsElement = [[NSXMLElement alloc] initWithName:@"defs" URI:kSVGNamespace];
        CFDictionaryApplyFunction(shadowCache, generateSVGShadowFilter, (void *)defsElement);
        CFDictionaryApplyFunction((__bridge CFDictionaryRef)fontSpecCache, generateSVGFontFace, (void *)defsElement);
        if ([defsElement childCount] > 0) {
            [svgElt insertChild:defsElement atIndex:0];
        }

        /* Simplify our generated SVG */
        removeRedundantGroups(svgElt);
        
        /* Fix up Apple lameness */
        assignNamespacePrefixes(svgElt);
        
        NSData *slz = [svgDoc XMLDataWithOptions:NSXMLNodePrettyPrint|NSXMLNodeCompactEmptyElement];
        fwrite([slz bytes], [slz length], 1, stdout);
        fputc('\n', stdout);
    }
    
    sqlite3_close(dbh);
    return 0;
}

static int checkApplicationID(void *ctxt, int colCount, char **values, char **names)
{
    if (colCount != 1 || !values[0])
        return SQLITE_ABORT;
    unsigned long magic = strtoul(values[0], NULL, 0);
    if (magic != 0x4163726E /* 'Acrn' */) {
        warnx("Incorrect db magic, expected 'Acrn', found %s", values[0]);
    } else {
        *(int *)ctxt = 1;
    }
    return SQLITE_OK;
}

int selectAttribute(sqlite3 *dbh, NSData *layer, const char *attname, void (^callback)(sqlite3_stmt *, int))
{
    int rv;
    sqlite3_stmt *sth;
    int count;
    
    sth = NULL;
    if (layer) {
        rv = sqlite3_prepare_v2(dbh, "SELECT value FROM layer_attributes WHERE id = ? AND name = ?;", -1, &sth, NULL);
        if (rv == SQLITE_OK) {
            rv = sqlite3_bind_text(sth, 1, [layer bytes], [layer length], SQLITE_TRANSIENT);
        }
        if (rv == SQLITE_OK) {
            rv = sqlite3_bind_text(sth, 2, attname, -1, SQLITE_TRANSIENT);
        }
    } else {
        rv = sqlite3_prepare_v2(dbh, "SELECT value FROM image_attributes WHERE name = ?;", -1, &sth, NULL);
        if (rv == SQLITE_OK) {
            rv = sqlite3_bind_text(sth, 1, attname, -1, SQLITE_TRANSIENT);
        }
    }
    if (rv != SQLITE_OK) {
        errx(2, "selectAttribute: prepare/bind: %s", sqlite3_errmsg(dbh));
    }
    
    count = 0;
    for(;;) {
        rv = sqlite3_step(sth);
        if (rv == SQLITE_DONE)
            break;
        else if (rv == SQLITE_BUSY) {
            usleep(10000);
        } else if (rv == SQLITE_ROW) {
            count ++;
            callback(sth, 0);
        } else {
            errx(2, "selectAttribute(%s,%s): step: %s", layer?"<layer>":"<doc>", attname, sqlite3_errmsg(dbh));
        }
    }
    
    sqlite3_finalize(sth);
    
    return count;
}

CFDataRef copyBlobValue(sqlite3_stmt *sth, int column)
{
    const void *ptr = sqlite3_column_blob(sth, column);
    if (!ptr)
        return NULL;
    
    return CFDataCreate(NULL, ptr, sqlite3_column_bytes(sth, column));
}

CFStringRef copyStringValue(sqlite3_stmt *sth, int column)
{
    const unsigned char *ptr = sqlite3_column_text(sth, column);
    if (!ptr)
        return NULL;
    
    return CFStringCreateWithBytes(NULL, ptr, sqlite3_column_bytes(sth, column), kCFStringEncodingUTF8, true);
}

/* Iterate over all the layers, create a tree of AcornLayer instances */
AcornLayer *copyLayerTree(sqlite3 *dbh)
{
    sqlite3_stmt *sth;
    int rv;
    
    sth = NULL;
    rv = sqlite3_prepare_v2(dbh, "SELECT id, parent_id, uti, name FROM layers ORDER BY sequence ASC;", -1, &sth, NULL);
    if (rv != SQLITE_OK) {
        errx(2, "select(all layers): prepare: %s", sqlite3_errmsg(dbh));
    }
    
    NSMutableArray *rootLayer = [[NSMutableArray alloc] init];
    NSMutableDictionary *children = [[NSMutableDictionary alloc] init];
    NSMutableDictionary *byOid = [[NSMutableDictionary alloc] init];
    
    for(;;) {
        rv = sqlite3_step(sth);
        if (rv == SQLITE_DONE)
            break;
        else if (rv == SQLITE_BUSY) {
            usleep(10000);
        } else if (rv == SQLITE_ROW) {
            CFDataRef oid = copyBlobValue(sth, 0);
            CFDataRef parent_oid = copyBlobValue(sth, 1);
            CFStringRef uti = copyStringValue(sth, 2);
            CFStringRef name = copyStringValue(sth, 3);
            
            AcornLayer *layer = [[AcornLayer alloc] initWithID:(__bridge NSData *)oid];
            layer.name = (__bridge_transfer NSString *)name;
            layer.uti = (__bridge_transfer NSString *)uti;
            
            [byOid setObject:layer forKey:(__bridge NSData *)oid];
            
            /* Because we selected ORDER BY sequence ASC, we just append to the layer arrays as they come in */
            if (parent_oid) {
                NSMutableArray *childList = [children objectForKey:(__bridge NSData *)parent_oid];
                if (!childList) {
                    childList = [[NSMutableArray alloc] init];
                    [children setObject:childList forKey:(__bridge NSData *)parent_oid];
                }
                [childList addObject:layer];
            } else {
                [rootLayer addObject:layer];
            }
            
            CFRelease(oid);
            if (parent_oid)
                CFRelease(parent_oid);
        } else {
            errx(2, "select(shapelayers): step: %s", sqlite3_errmsg(dbh));
        }
    }
    
    sqlite3_finalize(sth);
    
    [children enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        AcornLayer *parent = [byOid objectForKey:key];
        if (!parent) {
            warnx("Cannot find parent of child layer");
        } else {
            parent.children = obj;
        }
    }];
    
    AcornLayer *doc = [[AcornLayer alloc] initWithID:NULL];
    doc.name = @"<root>";
    doc.children = rootLayer;
    
    return doc;
}

CFDataRef copyLayerBlob(sqlite3 *dbh, NSData *oid)
{
    sqlite3_stmt *sth;
    int rv;
    CFDataRef blobdata;
    int count;
    
    sth = NULL;
    rv = sqlite3_prepare_v2(dbh, "SELECT data FROM layers WHERE id = ?;", -1, &sth, NULL);
    if (rv != SQLITE_OK) {
        errx(2, "select(layer): prepare: %s", sqlite3_errmsg(dbh));
    }
    rv = sqlite3_bind_text(sth, 1, [oid bytes], [oid length], SQLITE_TRANSIENT);
    if (rv != SQLITE_OK) {
        errx(2, "select(layer): bind: %s", sqlite3_errmsg(dbh));
    }
    
    blobdata = NULL;
    count = 0;
    for(;;) {
        rv = sqlite3_step(sth);
        if (rv == SQLITE_DONE)
            break;
        else if (rv == SQLITE_BUSY) {
            usleep(10000);
        } else if (rv == SQLITE_ROW) {
            count ++;
            blobdata = copyBlobValue(sth, 0);
            break;
        } else {
            errx(2, "select(layer): step: %s", sqlite3_errmsg(dbh));
        }
    }
    
    sqlite3_finalize(sth);
    
    if (!count) {
        warnf(@"no rows returned for layer %@", oid);
    }
    
    return blobdata;
}

@implementation AcornLayer

- (instancetype)initWithID:(NSData *)oid_
{
    self = [super init];
    if (self) {
        oid = oid_;
    }
    return self;
}

@synthesize name, uti, children;

- (void)prettyPrint:(int)indent;
{
    for(int i = 0; i < indent; i++) {
        fputc(' ', stdout);
        fputc(' ', stdout);
    }
    
    NSString *s = [NSString stringWithFormat:@"%@: %@\n", name, uti];
    fputs([s UTF8String], stdout);
    
    if (children)
        [children enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            [obj prettyPrint:indent+2];
        }];
}

- (void)addSVGToElement:(NSXMLElement *)parent height:(CGFloat)oheight dbh:(sqlite3 *)dbh;
{
    __block BOOL invisible = NO;
    __block NSRect frame = {{0, 0}, {0, 0}};
    
    selectAttribute(dbh, oid, "visible", ^(sqlite3_stmt *sth, int column){
        CFStringRef value = copyStringValue(sth, column);
        BOOL isVisible = boolForString((__bridge_transfer NSString *)value);
        if (!isVisible)
            invisible = YES;
    });
    
    if (invisible)
        return;
    
    NSXMLElement *elt = [[NSXMLElement alloc] initWithName:@"g" URI:kSVGNamespace];
    if (name && [name length]) {
        conditionallySetID(elt, name);
    }
    [parent addChild:elt];
    
    selectAttribute(dbh, oid, "frame", ^(sqlite3_stmt *sth, int column){
        CFStringRef value = copyStringValue(sth, column);
        frame = NSRectFromString((__bridge_transfer NSString *)value);
    });
    
    /* SVG measures Y from the top edge; Acorn is measuring it from the bottom edge. */
    CGFloat layerFrameTopY = oheight - frame.origin.y - frame.size.height;
    
    if (oid) {
        CFDataRef layerData = copyLayerBlob(dbh, oid);
        
        if ([uti isEqualToString:@"com.flyingmeat.acorn.shapelayer"]) {
            CFPropertyListRef value = CFPropertyListCreateWithData(NULL, layerData, kCFPropertyListImmutable, NULL, NULL);
            CFRelease(layerData);
            if (!value) {
                errx(1, "Could not parse plist for shape layer");
            }
            
            NSRect layerFrame = (NSRect){
              .origin = { frame.origin.x, layerFrameTopY },
              .size = frame.size
            };
            /* TODO: Do we need to do anything with the frame size? Clip paths? */
            /* TODO: Will this have the right effect if a layer is a child of another layer that has a nonzero origin? */
            
            /* TODO: Layer attributes:
             blendMode
             opacity
             */
            
            generateSVGForShape((__bridge NSDictionary *)value, &layerFrame, elt);
            CFRelease(value);
        } else {
            /* Assume all other UTIs are image types that CGImage can handle */
            
            NSXMLElement *imageElt = createImageElementFromData(uti, layerData, name);
            CFRelease(layerData);
            [elt addChild:imageElt];
            
            /* TODO: Layer attributes:
             blendMode
             opacity
             */
            
            if (frame.origin.x != 0 || layerFrameTopY != 0) {
                setFloatAttribute(imageElt, @"x", frame.origin.x);
                setFloatAttribute(imageElt, @"y", layerFrameTopY);
            }
            setFloatAttribute(imageElt, @"width", frame.size.width);
            setFloatAttribute(imageElt, @"height", frame.size.height);
        }
    }
    
    if (children) {
        /* TODO: Check what coordinate system child layers are in. Are they relative to our bounds, or relative to the doc? */
        [children enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            [obj addSVGToElement:elt height:oheight dbh:dbh];
        }];
    }
}

@end


#pragma mark - Bitmap conversion and output

@implementation WrittenImage

- (instancetype)initWithURL:(NSURL *)u;
{
    self = [super init];
    if (!self)
        return nil;
    onDisk = u;
    return self;
}

+ (instancetype)createFromSource:(CGImageSourceRef)src uti:(CFStringRef)uti overrides:(CFDictionaryRef)overrides;
{
    CFURLRef tmpname = NULL;
    CFStringRef extn = UTTypeCopyPreferredTagWithClass(uti, kUTTagClassFilenameExtension);
    /* Race-condition-prone */
    for(;;) {
        long rnum = random();
        CFStringRef filename = CFStringCreateWithFormat(NULL, NULL, CFSTR("img%lX.%@"), rnum, extn? extn : CFSTR("img"));
        tmpname = CFURLCreateWithString(NULL, filename, imageTmpDir);
        CFRelease(filename);
        if(!CFURLResourceIsReachable(tmpname, NULL))
            break;
        CFRelease(tmpname);
    }
    if (extn)
        CFRelease(extn);
    
    size_t imageCount = CGImageSourceGetCount(src);
    CGImageDestinationRef sink = CGImageDestinationCreateWithURL(tmpname, uti, imageCount, NULL);
    for(size_t imgIx = 0; imgIx < imageCount; imgIx++) {
        CGImageDestinationAddImageFromSource(sink, src, imgIx, overrides);
    }
    bool success = CGImageDestinationFinalize(sink);
    CFRelease(sink);
    
    if (success)
        return [[self alloc] initWithURL:(__bridge_transfer NSURL *)tmpname];
    else {
        CFRelease(tmpname);
        return nil;
    }
}

- (void)addElement:(NSXMLElement *)elt;
{
    NSXMLNode *attr = [NSXMLNode attributeWithName:@"href" URI:kXLINKNamespace stringValue:[onDisk absoluteString]];
    [elt addAttribute:attr];
}

@end

NSXMLElement *createImageElementFromData(NSString *uti, CFDataRef layerData, NSString *nameHint)
{
    if ([nameHint hasPrefix:@"Bitmap Layer "])
        nameHint = nil;
    
    /* TODO: Unique images based on hash of layer data */
    
    CFDictionaryRef opts;
    
    {
        CFStringRef kk[3] = { kCGImageSourceShouldCache, kCGImageSourceShouldAllowFloat, kCGImageSourceTypeIdentifierHint };
        CFTypeRef vv[3] = { kCFBooleanFalse, kCFBooleanTrue, (__bridge CFTypeRef)uti };
        opts = CFDictionaryCreate(NULL, (const void **)kk, (const void **)vv, 3,
                                  &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    
    CGImageSourceRef imgsrc = CGImageSourceCreateWithData(layerData, opts);
    if (CGImageSourceGetStatus(imgsrc) != kCGImageStatusComplete) {
        warnf(@"Could not read %@ data: image source status = %d", uti, (int)CGImageSourceGetStatus(imgsrc));
    cleanup_and_fail:
        CFRelease(opts);
        CFRelease(imgsrc);
        return nil;
    }
    size_t imageCount = CGImageSourceGetCount(imgsrc);
    if (imageCount < 1) {
        warnf(@"Could not read %@ data: contains no images", uti);
        goto cleanup_and_fail;
    }

#if 0
    warnf(@"Layer %@ -> %@, %u subimages", uti, (__bridge_transfer NSString *)CGImageSourceCopyProperties(imgsrc, opts), (unsigned)imageCount);
    for(size_t imgIx = 0; imgIx < imageCount; imgIx++) {
        warnf(@"  #%u: %@", (unsigned)imgIx, (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(imgsrc, imgIx, opts));
    }
#endif

    /* TODO: Acorn creates some image bitmap layers with only one pixel value (eg flat background fills). Replace those with <rect>s. */
#if 0
    if (imageCount == 1) {
        CGImageRef img = CGImageSourceCreateImageAtIndex(imgsrc, 0);
        NSColor *uniformColor = uniformColorOfImage(img);
        
        if (uniformColor) {
            NSXMLElement *rect = [[NSXMLElement alloc] initWithName:@"rect" URI:kSVGNamespace];

            setFloatAttribute(rect, @"width", CGImageGetWidth(img));
            setFloatAttribute(rect, @"height", CGImageGetHeight(img));
            applyPaint(rect, @"fill", @"fill-opacity", uniformColor);
            setStringAttribute(rect, @"stroke", @"none");
            
            CFRelease(img);
            return rect;
        }
        
        CFRelease(img);
    }
#endif
    
    /* TODO: Try various formats (png w/ different compression options; jpeg2000; jpeg) */
    /* TODO: Look at compression of original to guide format choice */
    
    WrittenImage *wrote  = [WrittenImage createFromSource:imgsrc uti:kUTTypePNG overrides:NULL];
    
    if (!wrote) {
        warnf(@"Could not write PNG data");
        goto cleanup_and_fail;
    }
    
    CFRelease(opts);
    CFRelease(imgsrc);
    
    NSXMLElement *elt = [[NSXMLElement alloc] initWithName:@"image" URI:kSVGNamespace];
    
    [wrote addElement:elt];
    [usedImages addObject:wrote];
    
    return elt;
}

#pragma mark - Shape layer to SVG conversion

void generateSVGForShape(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent)
{
    /*
     Shape layer graphic classes:
     
     Rectangle
     TextArea
     ArrowShape
     Line
     TSShapeLayer (top level, contains an array of graphics)
     
     Probable other classes:
     Circle       (=ellipse?)
     Freehand     (bezier?)
     ShapeImage   (=star?)
    */
    
    // warnf(@"Shapey shape: %@", [obj description]);
    
    NSString *cls = [obj objectForKey:akGraphicClass];
    if (!cls)
        cls = [obj objectForKey:akLayerClass];

    if ([cls isEqualToString:@"TSShapeLayer"]) {
        warnIfUnknownKeys(obj, @[ akLayerClass, akGraphicsList, akCompositingMode, akLayerName, akOpacity, akVisible ]);
        /* TODO: Process keys other than GraphicsList */
        NSXMLElement *group = [[NSXMLElement alloc] initWithName:@"g" URI:kSVGNamespace];
        [[obj objectForKey:akGraphicsList] enumerateObjectsUsingBlock:^(id child, NSUInteger idx, BOOL *stop) {
            generateSVGForShape(child, frame, group);
        }];
        [parent addChild:group];
    } else if ([cls isEqualToString:@"Rectangle"]) {
        generateSVGForRectangle(obj, frame, parent);
    } else if ([cls isEqualToString:@"TextArea"]) {
        generateSVGForTextArea(obj, frame, parent);
    } else if ([cls isEqualToString:@"ArrowShape"]) {
        generateSVGForArrow(obj, frame, parent);
    } else if ([cls isEqualToString:@"Line"]) {
        generateSVGForLine(obj, frame, parent);
    } else {
        warnf(@"Warning: unknown Acorn shape class \"%@\", ignoring", cls);
    }
}

#define XLATE_X(xcoord) ( frame->origin.x + (xcoord) )
#define XLATE_Y(ycoord) ( frame->origin.y - (ycoord) )

void generateSVGForRectangle(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent)
{
    warnIfUnknownKeys(obj, @[ akGraphicClass, akAntiAlias, akBlendMode, akBounds, akCornerRadius, akCustomStrokeStyleDash, akCustomStrokeStyleGap, akDrawsFill, akDrawsStroke, akFillColor, akGradientConfig, akHasCornerRadius, akHasShadow, akLineJoinStyle, akRotationAngle, akShadowBlurRadius, akShadowColor, akShadowOffset, akStrokeColor, akStrokeLineWidth, akStrokeStyle ]);
    
    BOOL fills = boolForKey(obj, akDrawsFill, NO);
    BOOL strokes = boolForKey(obj, akDrawsStroke, NO);
    if (!fills && !strokes)
        return;
    
    NSXMLElement *rect = [[NSXMLElement alloc] initWithName:@"rect" URI:kSVGNamespace];
    generateSVGForShadow(obj, parent, rect);
    [parent addChild:rect];
    
    NSRect bounds = NSRectFromString([obj objectForKey:akBounds]);
    setFloatAttribute(rect, @"x", XLATE_X(bounds.origin.x));
    setFloatAttribute(rect, @"y", XLATE_Y(bounds.origin.y + bounds.size.height));
    setFloatAttribute(rect, @"width", bounds.size.width);
    setFloatAttribute(rect, @"height", bounds.size.height);

    if (boolForKey(obj, akHasCornerRadius, NO)) {
        CGFloat radius = floatForKey(obj, akCornerRadius);
        if (radius > 1e-5) {
            setFloatAttribute(rect, @"rx", radius);
            setFloatAttribute(rect, @"ry", radius);
        }
    }
    
    applyFillStroke(rect, fills, strokes, obj);
    
    /* TODO: akAntiAlias, akBlendMode, akGradientConfig, akRotationAngle */
}

void generateSVGForTextArea(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent)
{
    warnIfUnknownKeys(obj, @[ akGraphicClass, akAntiAlias, akBlendMode, akBounds, akCornerRadius, akCustomStrokeStyleDash, akCustomStrokeStyleGap, akDrawsFill, akDrawsStroke, akFillColor, akHasCornerRadius, akHasShadow, akKeepBoundsWhenEditing, akLineJoinStyle, akRTFD, akRotationAngle, akShadowBlurRadius, akShadowColor, akShadowOffset, akStrokeColor, akStrokeStyle, akTextStrokeWidth ]);
    
    NSAttributedString *contents = [[NSAttributedString alloc] initWithRTFD:[obj objectForKey:akRTFD] documentAttributes:NULL];
    
    NSXMLElement *text = [[NSXMLElement alloc] initWithName:@"text" URI:kSVGNamespace];
    [parent addChild:text];
    
    NSRect bounds = NSRectFromString([obj objectForKey:akBounds]);
    setStringAttribute(text, @"transform",
                       [NSString stringWithFormat:@"translate(%@ %@)",
                                 svgStringFromFloat(XLATE_X(bounds.origin.x), nil),
                                 svgStringFromFloat(XLATE_Y(bounds.origin.y + bounds.size.height), nil)]);
    
    NSTextStorage *tstorage = [[NSTextStorage alloc] initWithAttributedString:contents];
    NSTextContainer *box = [[NSTextContainer alloc] initWithContainerSize:bounds.size];
    NSLayoutManager *textSetter = [[NSLayoutManager alloc] init];
    [textSetter addTextContainer:box];
    [tstorage addLayoutManager:textSetter];
    
    /* TODO: underlines, font stroke/outline, ... ? */
    
    /* Break up the laid-out text into <tspan>s. Font changes require a tspan change, and we also place each line fragment in a different tspan so that we don't have to emit the y-values for every character. */
    [tstorage enumerateAttributesInRange:(NSRange){0, [tstorage length]}
                                 options:0
                              usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop){
        NSFont *spanFont = [attrs objectForKey:NSFontAttributeName];
        NSColor *spanColor = [attrs objectForKey:NSForegroundColorAttributeName];

        /* Now find all line fragments which contain glyphs from this span of characters. */
        NSRange glyphRangeOfInterest = [textSetter glyphRangeForCharacterRange:range actualCharacterRange:NULL];
        NSUInteger nextGlyphToFind = glyphRangeOfInterest.location;
        while (nextGlyphToFind < glyphRangeOfInterest.location + glyphRangeOfInterest.length) {
            NSRange lineFragmentRange;
            NSRect lineFragmentRect = [textSetter lineFragmentRectForGlyphAtIndex:nextGlyphToFind
                                                                   effectiveRange:&lineFragmentRange];
            if (lineFragmentRange.location + lineFragmentRange.length > glyphRangeOfInterest.location + glyphRangeOfInterest.length)
                lineFragmentRange.length = glyphRangeOfInterest.location + glyphRangeOfInterest.length - lineFragmentRange.location;
            if (lineFragmentRange.location + lineFragmentRange.length <= nextGlyphToFind) {
                nextGlyphToFind ++;
                continue;
            }
            if (lineFragmentRange.location < nextGlyphToFind) {
                lineFragmentRange.length = lineFragmentRange.location + lineFragmentRange.length - nextGlyphToFind;
                lineFragmentRange.location = nextGlyphToFind;
            }
            
            /* Map our glyph run back to a character range. */
            NSRange runCharRange = [textSetter characterRangeForGlyphRange:lineFragmentRange actualGlyphRange:NULL];
            if (runCharRange.length == 0) {
                nextGlyphToFind = lineFragmentRange.location + lineFragmentRange.length;
                continue;
            }
            
            BOOL trimmedEOLChar;
            NSUInteger lineEndChar, lineContentsEndChar, endGlyphIndexToCareAboutPositioning;
            [[tstorage string] getLineStart:NULL end:&lineEndChar contentsEnd:&lineContentsEndChar forRange:runCharRange];
            if (lineContentsEndChar < (runCharRange.location + runCharRange.length) &&
                lineEndChar >= (runCharRange.location + runCharRange.length)) {
                /* Don't worry about the offsets of the EOL character */
                endGlyphIndexToCareAboutPositioning = [textSetter glyphIndexForCharacterAtIndex:lineEndChar-1];
                trimmedEOLChar = YES;
            } else {
                endGlyphIndexToCareAboutPositioning = lineFragmentRange.location + lineFragmentRange.length;
                trimmedEOLChar = NO;
            }

            /* Emit a <tspan> element for this character run */
            NSXMLElement *span = [[NSXMLElement alloc] initWithName:@"tspan" URI:kSVGNamespace];
            [text addChild:span];
            [span addChild:[NSXMLNode textWithStringValue:[[tstorage string] substringWithRange:runCharRange]]];
            if (spanFont) {
                applyFontAttributes(span, spanFont);
            }
            if (spanColor) {
                applyPaintForColor(span, @"fill", @"fill-opacity", spanColor);
            }
            
            NSRange simpleGlyphRange = [textSetter rangeOfNominallySpacedGlyphsContainingIndex:lineFragmentRange.location];

            /* We don't need to flip our coordinates further here: Apple's text system measures coordinates from the top edge of the text container. */
            if (simpleGlyphRange.location + simpleGlyphRange.length < endGlyphIndexToCareAboutPositioning) {
                NSMutableArray *xs = [[NSMutableArray alloc] init];
                NSMutableArray *ys = [[NSMutableArray alloc] init];
                for(NSUInteger charIndex = runCharRange.location; charIndex < (runCharRange.location + runCharRange.length); charIndex ++) {
                    NSPoint aPoint = [textSetter locationForGlyphAtIndex:[textSetter glyphIndexForCharacterAtIndex:charIndex]];
                    [xs addObject:svgStringFromFloat(aPoint.x + lineFragmentRect.origin.x, nil)];
                    [ys addObject:svgStringFromFloat(aPoint.y + lineFragmentRect.origin.y, nil)];
                }
                setStringAttribute(span, @"x", [xs componentsJoinedByString:@" "]);
                setStringAttribute(span, @"y", [ys componentsJoinedByString:@" "]);
            } else {
                NSPoint startPoint = [textSetter locationForGlyphAtIndex:lineFragmentRange.location];
                setFloatAttribute(span, @"x", startPoint.x + lineFragmentRect.origin.x);
                setFloatAttribute(span, @"y", startPoint.y + lineFragmentRect.origin.y);
                
                if (!trimmedEOLChar && spanFont!=nil && runCharRange.length > 1) {
                    /* Calculate a textLength value if we have an uncomplicated situation (nominal advances, no EOL jiggerypokery). This is optional but helps make sure text displays as we laid it out. */
                    NSUInteger lastCharGlyph = [textSetter glyphIndexForCharacterAtIndex:runCharRange.location + runCharRange.length - 1];
                    NSPoint endPoint = [textSetter locationForGlyphAtIndex:lastCharGlyph];
                    NSSize lastGlyphNominalAdvance = [spanFont advancementForGlyph:[textSetter glyphAtIndex:lastCharGlyph]];
                    setFloatAttribute(span, @"textLength", hypotf(endPoint.x + lastGlyphNominalAdvance.width - startPoint.x,
                                                                  endPoint.y + lastGlyphNominalAdvance.height - startPoint.y));
                }
            }
            
            nextGlyphToFind = lineFragmentRange.location + lineFragmentRange.length;
        }
     }];
    
    /* TODO: akAntiAlias, akBlendMode, akCornerRadius, akCustomStrokeStyleDash, akCustomStrokeStyleGap, akDrawsFill, akDrawsStroke, akFillColor, akHasCornerRadius, akHasShadow, akLineJoinStyle, akRotationAngle, akShadowBlurRadius, akShadowColor, akShadowOffset, akStrokeColor, akStrokeStyle, akTextStrokeWidth */
}

void generateSVGForArrow(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent)
{
    warnIfUnknownKeys(obj, @[ akGraphicClass, akAntiAlias, akBlendMode, akBounds, akCornerRadius, akCustomStrokeStyleDash, akCustomStrokeStyleGap, akDrawsFill, akDrawsStroke, akEndPoint, akFillColor, akHasCornerRadius, akHasShadow, akLineJoinStyle, akPath, akPointLength, akRotationAngle, akShadowBlurRadius, akShadowColor, akShadowOffset, akStartPoint, akStrokeColor, akStrokeLineWidth, akStrokeStyle ]);

    generateSVGForPathGraphic(obj, frame, parent);
    
    /* TODO: akRotationAngle */
}

void generateSVGForLine(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent)
{
    warnIfUnknownKeys(obj, @[ akGraphicClass, akAntiAlias, akBlendMode, akBounds, akCornerRadius, akCustomStrokeStyleDash, akCustomStrokeStyleGap, akDrawsFill, akDrawsStroke, akFMPath, akFillColor, akHasCornerRadius, akHasShadow, akLineJoinStyle, akPath, akRotationAngle, akShadowBlurRadius, akShadowColor, akShadowOffset, akStrokeColor, akStrokeLineWidth, akStrokeStyle ]);
    
    generateSVGForPathGraphic(obj, frame, parent);
    
    /* TODO: akRotationAngle */
}

void generateSVGForPathGraphic(NSDictionary *obj, const NSRect *frame, NSXMLElement *parent)
{
    NSBezierPath *savedPath = [NSUnarchiver unarchiveObjectWithData:[obj objectForKey:akPath]];
    
    BOOL fills = boolForKey(obj, akDrawsFill, NO);
    BOOL strokes = boolForKey(obj, akDrawsStroke, NO);
    if (!fills && !strokes)
        return;
    
    NSXMLElement *pathElt = [[NSXMLElement alloc] initWithName:@"path" URI:kSVGNamespace];
    generateSVGForShadow(obj, parent, pathElt);
    [parent addChild:pathElt];
    setStringAttribute(pathElt, @"d", svgOpsFromPath(savedPath, frame));
    applyFillStroke(pathElt, fills, strokes, obj);
    
    /* TODO: akAntiAlias, akBlendMode, akCornerRadius, akHasCornerRadius */
}

void generateSVGForShadow(NSDictionary *obj, NSXMLElement *parent, NSXMLElement *element)
{
    /* TODO: What is the z-ordering of shadows? Are they immediately below their element, below all elements in their layer, or what? */
    
    NSString *shadowName = filterNameForShadow(obj);
    if (shadowName) {
        NSString *elementName = [NSString stringWithFormat:@"graphic%u", ++graphicRefSequence];
        setStringAttribute(element, @"id", elementName);
        
        NSXMLElement *shadow = [[NSXMLElement alloc] initWithName:@"use" URI:kSVGNamespace];
        setStringAttribute(shadow, @"filter", [NSString stringWithFormat:@"url(#%@)", shadowName]);
        NSXMLNode *attr = [NSXMLNode attributeWithName:@"href" URI:kXLINKNamespace stringValue:[@"#" stringByAppendingString:elementName]];
        [shadow addAttribute:attr];
        
        NSString *shadowOffset = [obj objectForKey:akShadowOffset];
        if (shadowOffset) {
            NSSize value = NSSizeFromString([obj objectForKey:akShadowOffset]);
            if (value.width != 0 || value.height != 0) {
                setFloatAttribute(shadow, @"x", value.width);
                setFloatAttribute(shadow, @"y", - value.height);
            }
        }
        
        [parent addChild:shadow];
    }
}

static void generateSVGShadowFilter(const void *key, const void *value, void *context)
{
    NSDictionary *shadow = (__bridge NSDictionary *)value;
    NSXMLElement *defs = (__bridge NSXMLElement *)context;
    
    NSArray *parameters = [shadow objectForKey:@"parameters"];
    NSColor *shadowColor = [parameters objectAtIndex:0];
    BOOL needColorize = ![shadowColor isEqual:[NSColor blackColor]];
    NSString *blurRadius = [parameters objectAtIndex:1];
    
    NSXMLElement *shadowDefinition = [[NSXMLElement alloc] initWithName:@"filter" URI:kSVGNamespace];
    [defs addChild:shadowDefinition];
    setStringAttribute(shadowDefinition, @"id", [shadow objectForKey:@"name"]);
    setStringAttribute(shadowDefinition, @"filterUnits", @"objectBoundingBox");
    setStringAttribute(shadowDefinition, @"primitiveUnits", @"userSpaceOnUse");
    
    NSString *inputImage = @"SourceAlpha";
    
    if (![blurRadius isEqualToString:@"0"]) {
        NSXMLElement *karlFriedrich = [[NSXMLElement alloc] initWithName:@"feGaussianBlur" URI:kSVGNamespace];
        [shadowDefinition addChild:karlFriedrich];
        
        setStringAttribute(karlFriedrich, @"in", inputImage);
        setStringAttribute(karlFriedrich, @"stdDeviation", blurRadius);
        
        if (needColorize) {
            setStringAttribute(karlFriedrich, @"result", @"blur");
            inputImage = @"blur";
        }
    }
    
    if (needColorize) {
        NSXMLElement *tmbg = [[NSXMLElement alloc] initWithName:@"feFlood" URI:kSVGNamespace];
        [shadowDefinition addChild:tmbg];
        NSXMLElement *colorize = [[NSXMLElement alloc] initWithName:@"feComposite" URI:kSVGNamespace];
        [shadowDefinition addChild:colorize];
        
        applyPaintForColor(tmbg, @"flood-color", @"flood-opacity", shadowColor);
        setStringAttribute(tmbg, @"result", @"flood");
        setStringAttribute(colorize, @"in", @"flood");
        setStringAttribute(colorize, @"in2", inputImage);
        setStringAttribute(colorize, @"operator", @"in");
    }
}

void applyPaint(NSXMLElement *elt, NSString *attr, NSString *alpha, NSData *encodedColor)
{
    NSColor *paint = [NSUnarchiver unarchiveObjectWithData:encodedColor];
    if (![paint isKindOfClass:[NSColor class]]) {
        warnf(@"Unknown paint: expected an NSColor, got a %@", NSStringFromClass([paint class]));
        return;
    }
    
    applyPaintForColor(elt, attr, alpha, paint);
}

static unsigned int rescale(CGFloat component)
{
    component = floor(256 * component);
    if (component > 255)
        return 255;
    else
        return (int)component;
}

void applyPaintForColor(NSXMLElement *elt, NSString *attr, NSString *alpha, NSColor *color)
{
    /* TODO: Non-sRGB color spaces with ICC profiles, etc etc */
    
    color = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    CGFloat rgba[4];
    [color getComponents:rgba];
    
    /* Common named colors */
    if (rgba[0] == 0 && rgba[1] == 0 && rgba[2] == 0) {
        setStringAttribute(elt, attr, @"black");
    } else if (rgba[0] == 1 && rgba[1] == 1 && rgba[2] == 1) {
        setStringAttribute(elt, attr, @"white");
    } else {
        setStringAttribute(elt, attr, [NSString stringWithFormat:@"#%02X%02X%02X", rescale(rgba[0]), rescale(rgba[1]), rescale(rgba[2])]);
    }
    
    setFloatAttribute(elt, alpha, rgba[3]);
}

void applyFillStroke(NSXMLElement *elt, BOOL hasFill, BOOL hasStroke, NSDictionary *obj)
{
    if (hasFill) {
        applyPaint(elt, @"fill", @"fill-opacity", [obj objectForKey:akFillColor]);
    } else {
        setStringAttribute(elt, @"fill", @"none");
    }
    
    if (hasStroke) {
        CGFloat strokeWidth = floatForKey(obj, akStrokeLineWidth);
        if (strokeWidth > 1e-8) {
            setFloatAttribute(elt, @"stroke-width", strokeWidth);
            applyPaint(elt, @"stroke", @"stroke-opacity", [obj objectForKey:akStrokeColor]);
            applyLineJoin(elt, @"stroke-linejoin", [obj objectForKey:akLineJoinStyle]);
        } else {
            setStringAttribute(elt, @"stroke", @"none");
        }
    } else {
        setStringAttribute(elt, @"stroke", @"none");
    }
    
    /* TODO: akCustomStrokeStyleDash, akCustomStrokeStyleGap, akStrokeStyle */
}

NSString *filterNameForShadow(NSDictionary *obj)
{
    if (!boolForKey(obj, akHasShadow, NO))
        return nil;
    
    NSColor *shadowColor = [NSUnarchiver unarchiveObjectWithData:[obj objectForKey:akShadowColor]];
    if (![shadowColor isKindOfClass:[NSColor class]]) {
        warnf(@"Unknown shadow paint: expected an NSColor, got a %@", NSStringFromClass([shadowColor class]));
        return nil;
    }
    
    if ([shadowColor alphaComponent] < 1e-5)
        return nil;
    
    NSString *blurRadius = svgStringFromFloat(floatForKey(obj, akShadowBlurRadius), nil);
    
    NSArray *shadowDescr = [NSArray arrayWithObjects:shadowColor, blurRadius, nil];
    
    CFTypeRef found = NULL;
    if (CFDictionaryGetValueIfPresent(shadowCache, (__bridge const void *)shadowDescr, &found)) {
        return [(__bridge NSDictionary *)found objectForKey:@"name"];
    }
    
    NSString *name = [NSString stringWithFormat:@"shadow%u", 1 + (unsigned)CFDictionaryGetCount(shadowCache)];
    NSDictionary *record = @{ @"parameters" : shadowDescr,
                              @"name" : name };
    CFDictionaryAddValue(shadowCache, (__bridge const void *)shadowDescr, (__bridge const void *)record);
    return name;
}

void applyLineJoin(NSXMLElement *elt, NSString *attr, NSObject *value)
{
    int joinType;
    NSString *joinString;
    
    if (!value)
        return;
    
    if ([value isKindOfClass:[NSNumber class]]) {
        joinType = [(NSNumber *)value intValue];
    } else if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] == 1) {
        joinType = [(NSString *)value intValue];
    } else {
        errx(1, "unknown linejoin type");
    }
    
    switch(joinType) {
        case 0: joinString = @"miter"; break;
        case 1: joinString = @"round"; break;
        case 2: joinString = @"bevel"; break;
        default: errx(1, "unknown linejoin type");
    }
    
    setStringAttribute(elt, attr, joinString);
}

#pragma mark Bezier path utilities

void enumerateSubpaths(NSBezierPath *p, void (^blk)(NSInteger firstElt, NSInteger eltCount, BOOL closed))
{
    NSInteger eltCount = [p elementCount];
    NSInteger subpathFirst = 0;
    NSInteger eltIndex;
    for (eltIndex = 0; eltIndex < eltCount; eltIndex ++) {
        NSBezierPathElement op = [p elementAtIndex:eltIndex];
        if (op == NSMoveToBezierPathElement) {
            if (eltIndex > subpathFirst)
                blk(subpathFirst, eltIndex - subpathFirst, NO);
            subpathFirst = eltIndex;
        } else if (op == NSClosePathBezierPathElement) {
            blk(subpathFirst, eltIndex - subpathFirst, YES);
            subpathFirst = eltIndex + 1;
        }
    }
    if (eltIndex > subpathFirst)
        blk(subpathFirst, eltIndex - subpathFirst, NO);
}

NSString *fmtPoint(NSPoint p)
{
    return [NSString stringWithFormat:@"%@ %@", svgStringFromFloat(p.x, nil), svgStringFromFloat(p.y, nil)];
}

NSString *svgOpsFromPath(NSBezierPath *p, const NSRect *frame)
{
    NSMutableArray *ops = [[NSMutableArray alloc] init];
    CGFloat leftX = frame->origin.x;
    CGFloat topY = frame->origin.y;

#define fliplate(p) (p).y = topY - (p).y; (p).x += leftX;
    
    enumerateSubpaths(p, ^(NSInteger firstElt, NSInteger eltCount, BOOL closed){
        NSPoint pBuf[3];
        NSPoint startPoint, prevPoint;
        NSString *implicitNextOp;
        NSBezierPathElement op;
        
        // warnf(@" subpath: %d %+d %@", (int)firstElt, (int)eltCount, closed?@"closed":@"open");
        
        // Some NSBezierPath convenience methods result in weird zero-length subpaths; we just elide those.
        if (eltCount < 1)
            return;
        
        op = [p elementAtIndex:firstElt associatedPoints:pBuf];
        if (op != NSMoveToBezierPathElement) {
            warnf(@"NSBezierPath subpath at index %d starts with non-moveto (nocurrentpoint)", (int)firstElt);
            return;
        }
        
        // An isolated moveto has no effect
        if (eltCount < 2)
            return;
        
        fliplate(pBuf[0]);
        [ops addObject:[NSString stringWithFormat:@"M"]];
        [ops addObject:fmtPoint(pBuf[0])];
        startPoint = pBuf[0];
        prevPoint = pBuf[0];
        implicitNextOp = @"L";
        
#define InsertOp(op) do{ if (![op isEqualToString:implicitNextOp]) { [ops addObject:op]; implicitNextOp = op; } }while(0)
        
        for(NSInteger ix = 1; ix < eltCount; ix ++) {
            op = [p elementAtIndex:ix+firstElt associatedPoints:pBuf];
            fliplate(pBuf[0]);
            
            if (op == NSLineToBezierPathElement && ix > 1 && ix+1 == eltCount && closed && pBuf[0].x == startPoint.x && pBuf[0].y == startPoint.y) {
                // Elide the unnecessary lineto back to the start point in a nontrivial closed path.
                continue;
            }
            
            if (op == NSLineToBezierPathElement) {
                /* If we're already in relative-lineto mode, switching to v/h doesn't save us anything, and may cost us a mode switch afterwards. So don't do that. */
                BOOL alreadyRelative = [implicitNextOp isEqualToString:@"l"];
                if (!alreadyRelative && pBuf[0].x == prevPoint.x) {
                    InsertOp(@"v");
                    [ops addObject:svgStringFromFloat(pBuf[0].y - prevPoint.y, nil)];
                } else if (!alreadyRelative && pBuf[0].y == prevPoint.y) {
                    InsertOp(@"h");
                    [ops addObject:svgStringFromFloat(pBuf[0].x - prevPoint.x, nil)];
                } else {
                    NSString *abs = fmtPoint(pBuf[0]);
                    NSString *rel = fmtPoint((NSPoint){ pBuf[0].x - prevPoint.x, pBuf[0].y - prevPoint.y });
                    if ([abs length] <= [rel length]) {
                        InsertOp(@"L");
                        [ops addObject:abs];
                    } else {
                        InsertOp(@"l");
                        [ops addObject:rel];
                    }
                }
                
                prevPoint = pBuf[0];
            } else if (op == NSCurveToBezierPathElement) {
                InsertOp(@"C");
                [ops addObject:fmtPoint(pBuf[0])];
                fliplate(pBuf[1]);
                [ops addObject:fmtPoint(pBuf[1])];
                fliplate(pBuf[2]);
                [ops addObject:fmtPoint(pBuf[2])];
                prevPoint = pBuf[2];
            }
        }
        
        if (closed)
            [ops addObject:@"Z"];
    });
    
#undef InsertOp
#undef fliplate
    
    return [ops componentsJoinedByString:@" "];
}

#pragma mark Font utilities

void applyFontAttributes(NSXMLElement *span, NSFont *spanFont)
{
    NSDictionary *fontAttributes;
    
    /* The AppKit font system uniquely identifies a font by its name and point size (or matrix). */
    NSString *fontName = [spanFont fontName];
    fontAttributes = [fontSpecCache objectForKey:fontName];
    if (!fontAttributes) {
        fontAttributes = computeAttributesForFont(spanFont);
        [fontSpecCache setObject:fontAttributes forKey:fontName];
    }
    
    setFloatAttribute(span, @"font-size", [spanFont pointSize]);
    [fontAttributes enumerateKeysAndObjectsUsingBlock:^(id attrName, id attrValue, BOOL *stop) {
        setStringAttribute(span, attrName, attrValue);
    }];
}

NSDictionary *computeAttributesForFont(NSFont *spanFont)
{
    NSMutableDictionary *attrs = [[NSMutableDictionary alloc] init];
    NSFontDescriptor *fontDesc = [spanFont fontDescriptor];
    NSFontSymbolicTraits traits = [fontDesc symbolicTraits];
    NSInteger fontWeight = [[NSFontManager sharedFontManager] weightOfFont:spanFont];
    
    if (traits & NSFontItalicTrait) {
        // AppKit doesn't distinguish between italic and oblique. If we're really not sure, SVG prefers us to specify "italic", because of the way its font matching rules work. But let's guess from the PostScript name of the font.
        NSString *psName = [spanFont fontName];
        NSRange italic = [psName rangeOfString:@"italic" options:NSBackwardsSearch|NSCaseInsensitiveSearch];
        NSRange obliq = [psName rangeOfString:@"oblique" options:NSBackwardsSearch|NSCaseInsensitiveSearch];
        if (obliq.length > 0 && (italic.length == 0 || italic.location < obliq.location))
            [attrs setObject:@"oblique" forKey:@"font-style"];
        else
            [attrs setObject:@"italic" forKey:@"font-style"];
    }
    
    if (traits & NSFontBoldTrait || fontWeight > 5) {
        if(fontWeight == 7 || fontWeight <= 4)
            [attrs setObject:@"bold" forKey:@"font-weight"];
        else
            [attrs setObject:[NSString stringWithFormat:@"%u", 100*(unsigned)fontWeight] forKey:@"font-weight"];
    } else if (fontWeight < 5) {
        /* CSS2 defines weight 400 as normal, and 100 is the lightest weight. AppKit defines weight 5 as normal, and 0 is the lightest weight. */
        if (fontWeight == 4 || fontWeight == 3)
            [attrs setObject:@"300" forKey:@"font-weight"];
        else if (fontWeight == 2 || fontWeight == 1)
            [attrs setObject:@"200" forKey:@"font-weight"];
        else
            [attrs setObject:@"100" forKey:@"font-weight"];
    } else {
        [attrs setObject:@"normal" forKey:@"font-weight"];
    }
    
    if (traits & NSFontExpandedTrait)
        [attrs setObject:@"expanded" forKey:@"font-stretch"];
    else if (traits & NSFontCondensedTrait)
        [attrs setObject:@"condensed" forKey:@"font-stretch"];
    
    NSString *familySpec = [spanFont familyName];
    
    familySpec = [familySpec precomposedStringWithCanonicalMapping];
    if (!isCSSIdent(familySpec))
        familySpec = quoteCSSString(familySpec);
    
    if ([spanFont isFixedPitch])
        familySpec = [familySpec stringByAppendingString:@", monospace"];
    
    if ((traits & NSFontFamilyClassMask) == NSFontSansSerifClass) {
        familySpec = [familySpec stringByAppendingString:@", sans-serif"];
    } else if ((traits & NSFontFamilyClassMask) == NSFontScriptsClass) {
        familySpec = [familySpec stringByAppendingString:@", cursive"];
    } else if ((traits & NSFontFamilyClassMask) == NSFontOrnamentalsClass) {
        familySpec = [familySpec stringByAppendingString:@", fantasy"];
    } else if ((traits & NSFontFamilyClassMask) == NSFontOldStyleSerifsClass ||
               (traits & NSFontFamilyClassMask) == NSFontTransitionalSerifsClass ||
               (traits & NSFontFamilyClassMask) == NSFontModernSerifsClass ||
               (traits & NSFontFamilyClassMask) == NSFontClarendonSerifsClass ||
               (traits & NSFontFamilyClassMask) == NSFontSlabSerifsClass) {
        familySpec = [familySpec stringByAppendingString:@", serif"];
    }
    
    [attrs setObject:familySpec forKey:@"font-family"];
    
    return [attrs copy];
}

static void generateSVGFontFace(const void *fontName_, const void *fontAttributes_, void *defs_)
{
    NSString *fontName = (__bridge NSString *)fontName_;
    NSDictionary *fontAttributes = (__bridge NSDictionary *)fontAttributes_;
    NSXMLElement *defs = (__bridge NSXMLElement *)defs_;
    
    NSXMLElement *face = [[NSXMLElement alloc] initWithName:@"font-face" URI:kSVGNamespace];
    [defs addChild:face];
    
    NSXMLElement *sources = [[NSXMLElement alloc] initWithName:@"font-face-src" URI:kSVGNamespace];
    [face addChild:sources];
    
    NSXMLElement *localsource = [[NSXMLElement alloc] initWithName:@"font-face-name" URI:kSVGNamespace];
    [sources addChild:localsource];
    setStringAttribute(localsource, @"name", fontName);
    
    [fontAttributes enumerateKeysAndObjectsUsingBlock:^(id attrName, id attrValue, BOOL *stop) {
        /* The font-family attribute is the only one that is different between the <font-face> element and the elements that reference it */
        if ([attrName isEqualToString:@"font-family"])
            return;
        
        /* We don't include the font-size in <font-face>; we assume fonts are scalable, or at least that it's not our problem */
        if ([attrName isEqualToString:@"font-size"])
            return;
        
        setStringAttribute(face, attrName, attrValue);
    }];
    
    /* CSS2, and therefore SVG, specifies most font metrics with respect to the font's em-width. We'll assume that it's the same as the font's point size, which AFAIK is correct for AppKit/CoreText (and most computer font systems). */
    CGFloat emWidth = 16.0;
    NSFont *font = [NSFont fontWithName:fontName size:emWidth];

    setStringAttribute(face, @"font-family", [font familyName]);

    /* If we use CTFontGetUnitsPerEm(), we can emit these scaled to the font's actual underlying coordinate space, so that they are exact. However, there is no way to get to an NSFont's underlying CTFont without going through undocumented API like -[NSFont ctFontRef]. (This is because Apple's text people like to partially reinvent the wheel and then pretend that each new API is all you need. In recent versions of OSX, at least, you can go from a CTFont to a NSFont because they're toll-free bridged, but there's no documentation indicating the reverse is possible.) */
    unsigned gridSize = CTFontGetUnitsPerEm([font ctFontRef]); /* Often 2048 */
    
    /* If not specified, SVG's units-per-em defaults to 1000 */
    if (gridSize != 1000)
        setStringAttribute(face, @"units-per-em", [NSString stringWithFormat:@"%u", gridSize]);
    
    CGFloat emScale = gridSize / emWidth;
    
    setFloatAttribute(face, @"ascent",               emScale * [font ascender]);
    setFloatAttribute(face, @"descent",              emScale * [font descender]);
    setFloatAttribute(face, @"cap-height",           emScale * [font capHeight]);
    setFloatAttribute(face, @"x-height",             emScale * [font xHeight]);
    setFloatAttribute(face, @"slope",                emScale * [font italicAngle]);
    setFloatAttribute(face, @"underline-position",   emScale * [font underlinePosition]);
    setFloatAttribute(face, @"underline-thickness",  emScale * [font underlineThickness]);
    
#if 0
    NSRect bbox = [font boundingRectForFont];
    if (!CGRectIsEmpty(bbox)) {
        setStringAttribute(face, @"bbox", [NSString stringWithFormat:@"%@ %@ %@ %@",
                                           svgStringFromFloat(emScale * bbox.origin.x, nil),
                                           svgStringFromFloat(emScale * bbox.origin.y, nil),
                                           svgStringFromFloat(emScale * (bbox.origin.x + bbox.size.width), nil),
                                           svgStringFromFloat(emScale * (bbox.origin.y + bbox.size.height), nil)]);
    }
#endif
}


