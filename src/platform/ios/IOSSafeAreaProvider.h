#ifndef IOSSAFEAREAPROVIDER_H
#define IOSSAFEAREAPROVIDER_H

#include <QtGlobal>

#ifdef Q_OS_IOS

#include <QObject>

class IOSSafeAreaProvider : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int topInset READ topInset NOTIFY insetsChanged)
    Q_PROPERTY(int bottomInset READ bottomInset NOTIFY insetsChanged)

public:
    explicit IOSSafeAreaProvider(QObject *parent = nullptr);

    int topInset() const;
    int bottomInset() const;

    Q_INVOKABLE void update();

signals:
    void insetsChanged();

private:
    int m_topInset = 0;
    int m_bottomInset = 0;
};

#endif // Q_OS_IOS

#endif // IOSSAFEAREAPROVIDER_H
