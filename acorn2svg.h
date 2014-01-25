
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <sqlite3.h>

/* XML namespaces */
#define kSVGNamespace @"http://www.w3.org/2000/svg"
#define kXLINKNamespace @"http://www.w3.org/1999/xlink"

/* Shape layer keys */
#define akLayerClass @"class"
#define akCompositingMode @"compositingMode"
#define akVisible @"visible"
#define akOpacity @"opacity"
#define akLayerName @"layerName"
#define akGraphicsList @"GraphicsList"

/* Graphic item keys */
#define akAntiAlias @"AntiAlias"
#define akBlendMode @"BlendMode"
#define akBounds @"Bounds"
#define akGraphicClass @"Class"
#define akCornerRadius @"CornerRadius"
#define akCustomStrokeStyleDash @"CustomStrokeStyleDash"
#define akCustomStrokeStyleGap @"CustomStrokeStyleGap"
#define akDrawsFill @"DrawsFill"
#define akDrawsStroke @"DrawsStroke"
#define akEndPoint @"EndPoint"
#define akFillColor @"FillColor"
#define akFMPath @"FMPath"
#define akGradientConfig @"GradientConfig"
#define akHasCornerRadius @"HasCornerRadius"
#define akHasShadow @"HasShadow"
#define akKeepBoundsWhenEditing @"KeepBoundsWhenEditing"
#define akLineJoinStyle @"LineJoinStyle"
#define akPath @"Path"
#define akPointLength @"PointLength"
#define akRotationAngle @"RotationAngle"
#define akRTFD @"RTFD"
#define akShadowBlurRadius @"ShadowBlurRadius"
#define akShadowColor @"ShadowColor"
#define akShadowOffset @"ShadowOffset"
#define akStartPoint @"StartPoint"
#define akStrokeColor @"StrokeColor"
#define akStrokeLineWidth @"StrokeLineWidth"
#define akStrokeStyle @"StrokeStyle"
#define akTextStrokeWidth @"TextStrokeWidth"

@interface AcornLayer : NSObject
{
    NSData *oid;
    NSString *name;
    NSString *uti;
    NSMutableArray *children;
}

- (instancetype)initWithID:(NSData *)oid;

@property (readwrite,copy,nonatomic) NSString *name;
@property (readwrite,copy,nonatomic) NSString *uti;
@property (readwrite,copy,nonatomic) NSArray *children;

- (void)prettyPrint:(int)indent;
- (void)addSVGToElement:(NSXMLElement *)parent height:(CGFloat)oheight dbh:(sqlite3 *)dbh;

@end

@interface WrittenImage : NSObject
{
    NSURL *onDisk;
    NSMutableArray *elements;
}

+ (instancetype)createFromSource:(CGImageSourceRef)src uti:(CFStringRef)uti overrides:(CFDictionaryRef)overrides;
- (void)addElement:(NSXMLElement *)elt;

@end


/* Utilities */
void warnIfUnknownKeys(NSDictionary *dict, NSArray *keys);
BOOL boolForKey(NSDictionary *dict, NSString *key, BOOL dflt);
BOOL boolForString(NSString *s);
CGFloat floatForKey(NSDictionary *dict, NSString *key);
void warns(NSString *msg);
#define warnf(fmt, ...) warns([NSString stringWithFormat:fmt, ## __VA_ARGS__])

/* SVG Utilities */
void assignNamespacePrefixes(NSXMLElement *elt);
void removeRedundantGroups(NSXMLElement *nd);
void conditionallySetID(NSXMLElement *elt, NSString *name);
void setStringAttribute(NSXMLElement *elt, NSString *name, NSString *value);
NSString *svgStringFromFloat(CGFloat value, NSString *suffix);
void setFloatAttribute(NSXMLElement *elt, NSString *name, CGFloat value);
static inline void setFloatAttributeSuffixed(NSXMLElement *elt, NSString *name, CGFloat value, NSString *suffix) {
    setStringAttribute(elt, name, svgStringFromFloat(value, suffix));
}

