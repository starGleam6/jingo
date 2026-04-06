/**
 * @file XBoardNormalizer.h
 * @brief XBoard 面板数据归一化器头文件
 * @details 将 XBoard 特有的数据格式转换为 EzPanel 标准格式
 * @author JinGo VPN Team
 * @date 2025
 */

#ifndef XBOARDNORMALIZER_H
#define XBOARDNORMALIZER_H

#include "panel/IPanelDataNormalizer.h"

/**
 * @class XBoardNormalizer
 * @brief XBoard 面板数据归一化器
 *
 * @details
 * XBoard 与 EzPanel 标准格式的主要差异：
 *
 * 1. 邀请信息 (normalizeInviteInfo):
 *    - stat 字段：XBoard 返回数组 [registered, valid_commission, pending_commission, rate, balance]
 *      → 转为对象 {registered_count, total_commission, commission_rate, commission_balance}
 *    - invite_url 字段：XBoard 不提供，需从 panelUrl + code 拼接
 */
class XBoardNormalizer : public IPanelDataNormalizer
{
public:
    XBoardNormalizer() = default;
    ~XBoardNormalizer() override = default;

    /**
     * @brief 归一化邀请信息
     * @param raw XBoard 原始邀请数据
     * @return QJsonObject EzPanel 标准格式
     */
    QJsonObject normalizeInviteInfo(const QJsonObject& raw) override;

    /**
     * @brief 归一化用户统计
     * @param raw XBoard 原始统计数据 {"data": [pending_orders, pending_tickets, invited_count]}
     * @return QJsonObject 统一对象格式
     */
    QJsonObject normalizeUserStats(const QJsonObject& raw) override;
};

#endif // XBOARDNORMALIZER_H
