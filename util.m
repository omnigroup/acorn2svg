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

#include <err.h>

#import "acorn2svg.h"

#pragma mark SVG generation utilities

NSString *svgStringFromFloat(CGFloat value, NSString *suffix)
{
    NSString *v = [NSString stringWithFormat:@"%.4f", value];
    if ([v rangeOfString:@"."].length > 0) {
        NSMutableString *trim = [v mutableCopy];
        NSRange r;
        for(;;) {
            r = [trim rangeOfString:@"0" options:NSBackwardsSearch|NSAnchoredSearch];
            if (r.length) {
                [trim replaceCharactersInRange:r withString:@""];
            } else {
                break;
            }
        }
        r = [trim rangeOfString:@"." options:NSBackwardsSearch|NSAnchoredSearch];
        if (r.length) {
            [trim replaceCharactersInRange:r withString:@""];
        }
        if (suffix)
            [trim appendString:suffix];
        return trim;
    } else {
        if (suffix)
            return [v stringByAppendingString:suffix];
        else
            return v;
    }
}

void setFloatAttribute(NSXMLElement *elt, NSString *name, CGFloat value)
{
    setStringAttribute(elt, name, svgStringFromFloat(value, nil));
}

void setStringAttribute(NSXMLElement *elt, NSString *name, NSString *value)
{
    NSXMLNode *attr = [NSXMLNode attributeWithName:name stringValue:value];
    [elt addAttribute:attr];
}

void conditionallySetID(NSXMLElement *elt, NSString *someString)
{
    /* We might want to assign XML IDs based on the layer name. If so, we'll need to gather them up, make them into valid XMLIDs, deal with any collisions, and assign them to the NSXMLElements representing the layers. */
}

/* Apple produced an API that looks like it supports namespaces usefully but actually doesn't do much--- all it does is store the URI of an element or tag name; it doesn't write out qualified names by itself. Here we go through and fix up all element and attribute names to have the correct prefix. Before calling this, any namespaces you use must have been declared on an ancestor of the nodes that use them. */
void assignNamespacePrefixes(NSXMLElement *elt)
{
    [[elt attributes] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSXMLNode *attr = (NSXMLNode *)obj;
        NSString *uri = [attr URI];
        NSString *localName = [attr localName];
        if (!uri) {
            /* Unprefixed attribute names are always unqualified; we don't have to worry about a default namespace here */
            [attr setName:localName];
        } else {
            NSString *pfx = [elt resolvePrefixForNamespaceURI:uri];
            if (!pfx) {
                errx(1, "Namespace used without declaration");
            }
            if ([pfx isEqualToString:@""]) {
                /* In order to write this out correctly, we would need to have another namespace declaration somewhere giving a prefix to this namespace so that we can explicitly qualify this attribute name in that namespace. But we don't have a good way to find such a namespace decl without reimplementing -resolvePrefixForNamespaceURI: ourselves. Generally, if you're trying to do anything fancy, don't use NSXML. */
                errx(1, "Attribute is in the default namespace");
            }
            [attr setName:[NSString stringWithFormat:@"%@:%@", pfx, localName]];
        }
    }];
    
    NSString *uri = [elt URI];
    NSString *localName = [elt localName];
    if (!uri) {
        /* This is only OK if there's no default namespace in effect (or if we're smart enough to un-declare the default namespace for this element's benefit, which we're not). Writing an SVG file, we declare a default SVG namespace on the root element; and an unqualified element name in our document is likely a bug anyway. */
        errx(1, "Element not in any namespace");
    } else {
        NSString *pfx = [elt resolvePrefixForNamespaceURI:uri];
        if (!pfx) {
            errx(1, "Namespace used without declaration");
        }
        if ([pfx isEqualToString:@""]) {
            /* Element is in the default namespace */
            [elt setName:localName];
        } else {
            /* Apply a prefix */
            [elt setName:[NSString stringWithFormat:@"%@:%@", pfx, localName]];
        }
    }
    
    [[elt children] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([(NSXMLNode *)obj kind] == NSXMLElementKind)
            assignNamespacePrefixes((NSXMLElement *)obj);
    }];
}

/* Simplify the document by removing groups with only one element */
void removeRedundantGroups(NSXMLElement *nd)
{
    NSUInteger childIndex = [nd childCount];
    while(childIndex--) {
        NSXMLNode *child = [nd childAtIndex:childIndex];
        if ([child kind] == NSXMLElementKind) {
            NSXMLElement *childElement = (NSXMLElement *)child;
            while ([[childElement localName] isEqualToString:@"g"] && [[childElement URI] isEqualToString:kSVGNamespace] &&
                   [childElement childCount] == 1 &&
                   [[childElement attributes] count] == 0) {
                NSXMLElement *grandchild = (NSXMLElement *)[childElement childAtIndex:0];
                [childElement removeChildAtIndex:0];
                [nd replaceChildAtIndex:childIndex withNode:grandchild];
                childElement = grandchild;
            }
            removeRedundantGroups(childElement);
        }
    }
}

static NSCharacterSet *non_nmchars = nil;
static NSCharacterSet *dubious_qstring = nil;
static dispatch_once_t css_charsets_sem;
static void css_charsets_init(void *dummy)
{
    NSMutableCharacterSet *cs = [[NSMutableCharacterSet alloc] init];
    [cs addCharactersInRange:(NSRange){0, 255}];
    [cs invert];
    [cs formUnionWithCharacterSet:[NSCharacterSet alphanumericCharacterSet]];
    [cs addCharactersInString:@"0123456789-_"];
    [cs invert];
    non_nmchars = [cs copy];
    
    cs = [[NSMutableCharacterSet alloc] init];
    [cs addCharactersInRange:(NSRange){0, 31}];
    [cs addCharactersInString:@"'\"\\"];
    [cs formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]];
    [cs formUnionWithCharacterSet:[NSCharacterSet illegalCharacterSet]];
    dubious_qstring = [cs copy];
}

/* Check whether a string matches the CSS2 "IDENT" production in such a way that it represents itself in a CSS file (e.g., no backslashes) */
BOOL isCSSIdent(NSString *s)
{
    NSUInteger len = [s length];
    NSUInteger chIndex;

    if (len < 1)
        return NO;
    chIndex = 0;
    if ([s characterAtIndex:0] == '-')
        chIndex = 1;
    if (len < chIndex + 1)
        return NO;

    dispatch_once_f(&css_charsets_sem, NULL, css_charsets_init);

    NSRange r = [s rangeOfCharacterFromSet:non_nmchars options:0 range:(NSRange){chIndex, len-chIndex}];
    if (r.length > 0)
        return 0;

    if([@"0123456789_" rangeOfString:[s substringWithRange:[s rangeOfComposedCharacterSequenceAtIndex:chIndex]]].length != 0)
        return NO;

    return YES;
}

NSString *quoteCSSString(NSString *s)
{
    NSString *quoteCharacter;
    NSString *otherQuoteCharacter;
    
    /* Use single-quotes, unless the string we're quoting has single-quotes but not double-quotes in it. */
    if ([s rangeOfString:@"'"].length == 0 || [s rangeOfString:@"\""].length != 0) {
        quoteCharacter = @"'";
        otherQuoteCharacter = @"\"";
    } else {
        quoteCharacter = @"\"";
        otherQuoteCharacter = @"'";
    }
    
    dispatch_once_f(&css_charsets_sem, NULL, css_charsets_init);
    
    NSMutableString *buf = [s mutableCopy];
    NSUInteger sindex = 0;
    NSUInteger slen = [buf length];
    while (sindex < slen) {
        NSRange r = [buf rangeOfCharacterFromSet:dubious_qstring options:0 range:(NSRange){sindex, slen-sindex}];
        if (r.length == 0)
            break;
        sindex += r.length;
        
        NSString *substr = [buf substringWithRange:r];
        if (![substr isEqualToString:otherQuoteCharacter]) {
            NSMutableString *escbuf = [[NSMutableString alloc] init];
            for (NSUInteger subindex = 0; subindex < r.length; subindex ++) {
                unichar ch = [substr characterAtIndex:subindex];
                if (ch == '\\') {
                    [escbuf appendString:@"\\\\"];
                } else if (ch == '"') {
                    [escbuf appendString:@"\\\""];
                } else if (ch == '\'') {
                    [escbuf appendString:@"\\'"];
                } else {
                    [escbuf appendFormat:@"\\%06X", ch];
                }
            }
            [buf replaceCharactersInRange:r withString:escbuf];
            sindex += [escbuf length] - r.length;
            slen = [buf length];
        }
    }
    
    [buf replaceCharactersInRange:(NSRange){0, 0} withString:quoteCharacter];
    [buf replaceCharactersInRange:(NSRange){[buf length], 0} withString:quoteCharacter];
    
    return buf;
}

#pragma mark Miscellaneous other utilities

void warnIfUnknownKeys(NSDictionary *dict, NSArray *keys)
{
    [dict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if (![keys containsObject:key]) {
            NSString *cls = [dict objectForKey:akGraphicClass];
            if (!cls)
                cls = [dict objectForKey:akLayerClass];
            warnf(@"Warning: unknown key \"%@\" (in %@), ignoring", key, cls);
        }
    }];
}

BOOL boolForString(NSString *s)
{
    s = [s lowercaseString];
    if ([s isEqualToString:@"0"] || [s rangeOfString:@"n" options:NSAnchoredSearch].length > 0)
        return NO;
    if ([s isEqualToString:@"1"] || [s rangeOfString:@"y" options:NSAnchoredSearch].length > 0)
        return YES;
    errx(1, "boolean string has unexpected value");
}

BOOL boolForKey(NSDictionary *dict, NSString *key, BOOL dflt)
{
    NSObject *value = [dict objectForKey:key];
    if (!value)
        return dflt;
    
    if ([value isKindOfClass:[NSNumber class]])
        return [(NSNumber *)value boolValue];
    
    if ([value isKindOfClass:[NSString class]]) {
        return boolForString((NSString *)value);
    }
    
    errx(1, "boolean key has unexpected value");
}

CGFloat floatForKey(NSDictionary *dict, NSString *key)
{
    NSObject *value = [dict objectForKey:key];
    if (!value)
        errx(1, "missing key (expected a float)");
    
    return (CGFloat)[(NSNumber *)value doubleValue];
}

void warns(NSString *msg)
{
    fputs([msg UTF8String], stderr);
    fputc('\n', stderr);
}

void trimTrailingRepeats(NSMutableArray *a)
{
    NSUInteger aCount = [a count];
    
    while (aCount >= 2 && [[a objectAtIndex:aCount-2] isEqual:[a objectAtIndex:aCount-1]]) {
        [a removeObjectAtIndex:aCount-1];
        aCount --;
    }
}
