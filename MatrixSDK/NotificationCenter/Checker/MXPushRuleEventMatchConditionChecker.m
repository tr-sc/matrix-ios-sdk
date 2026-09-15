/*
 Copyright 2015 OpenMarket Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXPushRuleEventMatchConditionChecker.h"

@interface MXPushRuleEventMatchConditionChecker ()
{
    NSMutableDictionary* regExByPatternDict;
}
@end

@implementation MXPushRuleEventMatchConditionChecker

- (BOOL)isCondition:(MXPushRuleCondition*)condition satisfiedBy:(MXEvent*)event roomState:(MXRoomState*)roomState withJsonDict:(NSDictionary*)contentAsJsonDict
{
    if ([condition.kind isEqualToString:@"event_property_is"] || [condition.kind isEqualToString:@"event_property_contains"])
    {
        NSString *key = condition.parameters[@"key"];
        id expected = condition.parameters[@"value"];
        if (![key isKindOfClass:NSString.class] || !expected) { return NO; }
        id value = [self propertyAtPath:key inDictionary:contentAsJsonDict];
        if ([condition.kind isEqualToString:@"event_property_is"])
        {
            return [self scalar:value equals:expected];
        }
        if (![value isKindOfClass:NSArray.class]) { return NO; }
        for (id item in value)
        {
            if ([self scalar:item equals:expected]) { return YES; }
        }
        return NO;
    }
    BOOL isSatisfied = NO;
    
    NSString *key = (NSString *)condition.parameters[@"key"];
    NSString *pattern = (NSString *)condition.parameters[@"pattern"];
    
    // Use the decrypted body when searching for @room.
    if ([key isEqualToString:@"content.body"] && [pattern isEqualToString:@"@room"])
    {
        return [self decryptedBodyOfEvent:event containsString:pattern];
    }
    
    // Otherwise retrieve the value from the original JSON.
    NSObject *value = [self propertyAtPath:key inDictionary:contentAsJsonDict];
    
    if (value && [value isKindOfClass:[NSString class]])
    {
        // If it exists, compare it to the regular expression in condition.parameter.pattern
        NSString *stringValue = (NSString *)value;
        
        // if there is no pattern
        if (!pattern || !pattern.length)
        {
            // cannot match
            return NO;
        }
        
        // the regexs are cached to avoid creating them at each call
        // and it also should speed up it/
        if (!regExByPatternDict)
        {
            regExByPatternDict = [[NSMutableDictionary alloc] init];
        }
        

        NSRegularExpression *regex = [regExByPatternDict objectForKey:pattern];

        // not yet defined
        if (!regex)
        {
            // defined it.
            regex = [NSRegularExpression regularExpressionWithPattern:[self globToRegex:pattern] options:NSRegularExpressionCaseInsensitive error:nil];
            [regExByPatternDict setObject:regex forKey:pattern];
        }
           

        if ([regex numberOfMatchesInString:stringValue options:0 range:NSMakeRange(0, stringValue.length)])
        {
            isSatisfied = YES;
        }
    }

    return isSatisfied;
}

// Matrix property paths escape literal dots/backslashes; KVC is not a JSON path parser.
- (id)propertyAtPath:(NSString *)path inDictionary:(NSDictionary *)dictionary
{
    if (![path isKindOfClass:NSString.class] || !path.length) { return nil; }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableString *part = [NSMutableString string];
    BOOL escaped = NO;
    for (NSUInteger index = 0; index < path.length; index++)
    {
        unichar character = [path characterAtIndex:index];
        if (escaped)
        {
            if (character != '.' && character != '\\') { [part appendString:@"\\"]; }
            [part appendFormat:@"%C", character];
            escaped = NO;
        }
        else if (character == '\\') { escaped = YES; }
        else if (character == '.') { [parts addObject:part.copy]; [part setString:@""]; }
        else { [part appendFormat:@"%C", character]; }
    }
    if (escaped) { [part appendString:@"\\"]; }
    [parts addObject:part];
    id value = dictionary;
    for (NSString *component in parts)
    {
        if (![value isKindOfClass:NSDictionary.class]) { return nil; }
        value = value[component];
    }
    return value;
}

- (BOOL)scalar:(id)value equals:(id)expected
{
    if (!value || !expected) { return NO; }
    if ([value isKindOfClass:NSString.class] && [expected isKindOfClass:NSString.class])
    {
        return [value isEqualToString:expected];
    }
    if ([value isKindOfClass:NSNumber.class] && [expected isKindOfClass:NSNumber.class])
    {
        BOOL valueIsBool = CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
        BOOL expectedIsBool = CFGetTypeID((__bridge CFTypeRef)expected) == CFBooleanGetTypeID();
        return valueIsBool == expectedIsBool && [value isEqualToNumber:expected];
    }
    return value == NSNull.null && expected == NSNull.null;
}

- (NSString*)globToRegex:(NSString*)glob
{
    NSString *res = [glob stringByReplacingOccurrencesOfString:@"*" withString:@".*"];
    res = [res stringByReplacingOccurrencesOfString:@"?" withString:@"."];
    
    // In all cases, enable world delimiters
    res = [NSString stringWithFormat:@"(^|\\W)%@($|\\W)", res];

    return res;
}

- (BOOL)decryptedBodyOfEvent:(MXEvent *)event
             containsString:(NSString *)pattern
{
    if (!event.content)
    {
        return NO;
    }
    
    if (![event.content[kMXMessageBodyKey] isKindOfClass:NSString.class])
    {
        return NO;
    }
    
    NSString *body = (NSString *)event.content[kMXMessageBodyKey];
    return [body containsString:pattern];
}

@end
