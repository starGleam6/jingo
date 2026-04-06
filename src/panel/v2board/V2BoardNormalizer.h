/**
 * @file V2BoardNormalizer.h
 * @brief V2Board 面板数据归一化器
 * @details 处理 V2Board 返回数据与统一格式之间的差异
 * @author JinGo VPN Team
 * @date 2025
 */

#ifndef V2BOARDNORMALIZER_H
#define V2BOARDNORMALIZER_H

#include <panel/IPanelDataNormalizer.h>

/**
 * @class V2BoardNormalizer
 * @brief V2Board 面板数据归一化器
 *
 * @details
 * V2Board 数据格式与统一格式的主要差异：
 * - 用户信息字段名不同: transfer_enable→total_traffic, u→used_upload, d→used_download,
 *   expired_at→expire_time
 * - 邀请信息 (normalizeInviteInfo):
 *   - stat 字段：V2Board 某些版本返回数组 [registered, commission_pending, commission_valid, rate]
 *     → 转为对象 {registered_count, total_commission, commission_rate, commission_balance}
 *   - invite_url 字段：V2Board 不一定提供，需从 panelUrl + code 拼接
 */
class V2BoardNormalizer : public IPanelDataNormalizer
{
public:
    V2BoardNormalizer() = default;
    ~V2BoardNormalizer() override = default;

    QJsonObject normalizeUserInfo(const QJsonObject& raw) override;

    /**
     * @brief 归一化邀请信息
     * @param raw V2Board 原始邀请数据
     * @return QJsonObject 统一格式
     */
    QJsonObject normalizeInviteInfo(const QJsonObject& raw) override;

    /**
     * @brief 归一化用户流量统计
     * @param raw V2Board 原始数据（data 字段为数组: [昨日流量, 昨日剩余, 今日流量, 今日剩余]）
     * @return QJsonObject 统一对象格式
     */
    QJsonObject normalizeUserStats(const QJsonObject& raw) override;
};

#endif // V2BOARDNORMALIZER_H
