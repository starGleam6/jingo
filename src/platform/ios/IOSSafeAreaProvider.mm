#include "IOSSafeAreaProvider.h"

#ifdef Q_OS_IOS

#import <UIKit/UIKit.h>

IOSSafeAreaProvider::IOSSafeAreaProvider(QObject *parent)
    : QObject(parent)
{
    update();
}

int IOSSafeAreaProvider::topInset() const
{
    return m_topInset;
}

int IOSSafeAreaProvider::bottomInset() const
{
    return m_bottomInset;
}

void IOSSafeAreaProvider::update()
{
    int top = 0;
    int bottom = 0;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = nil;
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                scene = (UIWindowScene *)s;
                break;
            }
        }
        if (scene) {
            UIWindow *window = scene.windows.firstObject;
            if (window) {
                UIEdgeInsets insets = window.safeAreaInsets;
                top = (int)insets.top;
                bottom = (int)insets.bottom;
            }
        }
    }

    if (top != m_topInset || bottom != m_bottomInset) {
        m_topInset = top;
        m_bottomInset = bottom;
        emit insetsChanged();
    }
}

#endif // Q_OS_IOS
