/**
 * @file XBoardProvider.h
 * @brief XBoard 面板提供者头文件
 * @details XBoard 与 EzPanel API 端点兼容，继承 EzPanelProvider 仅覆盖面板信息
 * @author JinGo VPN Team
 * @date 2025
 */

#ifndef XBOARDPROVIDER_H
#define XBOARDPROVIDER_H

#include "panel/ezpanel/EzPanelProvider.h"

/**
 * @class XBoardProvider
 * @brief XBoard 面板提供者
 *
 * @details
 * XBoard 与 EzPanel 共享相同的 API 端点，因此直接继承 EzPanelProvider。
 * 仅覆盖面板类型信息（panelType、panelName），API 行为完全复用父类。
 * 数据格式差异由 XBoardNormalizer 处理。
 */
class XBoardProvider : public EzPanelProvider
{
    Q_OBJECT

public:
    explicit XBoardProvider(QObject* parent = nullptr)
        : EzPanelProvider(parent) {}

    PanelType panelType() const override { return PanelType::XBoard; }
    QString panelName() const override { return "XBoard"; }
};

#endif // XBOARDPROVIDER_H
