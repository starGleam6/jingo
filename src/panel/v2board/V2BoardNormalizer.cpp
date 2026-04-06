/**
 * @file V2BoardNormalizer.cpp
 * @brief V2Board 面板数据归一化器实现
 * @author JinGo VPN Team
 * @date 2025
 */

#include "V2BoardNormalizer.h"
#include "core/BundleConfig.h"
#include <QJsonArray>
#include <QJsonValue>

QJsonObject V2BoardNormalizer::normalizeUserInfo(const QJsonObject& raw)
{
    // 保留所有原始字段（User::fromJson 直接使用 transfer_enable, u, d, expired_at 等）
    // 仅补充计算字段供 ViewModel 层直接使用
    QJsonObject result = raw;

    qint64 transferEnable = raw["transfer_enable"].toVariant().toLongLong();
    qint64 uploaded = raw["u"].toVariant().toLongLong();
    qint64 downloaded = raw["d"].toVariant().toLongLong();

    result["used_traffic"] = uploaded + downloaded;
    result["remaining_traffic"] = transferEnable - uploaded - downloaded;

    return result;
}

QJsonObject V2BoardNormalizer::normalizeInviteInfo(const QJsonObject& raw)
{
    QJsonObject result = raw;

    // V2Board stat 是数组格式:
    // [0] 已注册用户数
    // [1] 有效的佣金（commission_log.get_amount 总和）
    // [2] 确认中的佣金（待处理订单的佣金）
    // [3] 佣金比例 %
    // [4] 可用佣金余额（user.commission_balance，可提现）
    // 统一格式是对象: {registered_count, total_commission, commission_rate, commission_balance}
    QJsonValue statValue = raw.value("stat");
    if (statValue.isArray()) {
        QJsonArray stat = statValue.toArray();
        QJsonObject normalizedStat;
        normalizedStat["registered_count"]   = stat.size() > 0 ? stat[0].toInt(0) : 0;
        normalizedStat["total_commission"]   = stat.size() > 1 ? stat[1].toInt(0) : 0;
        normalizedStat["commission_rate"]    = stat.size() > 3 ? stat[3].toInt(0) : 0;
        normalizedStat["commission_balance"] = stat.size() > 4 ? stat[4].toInt(0) : 0;
        result["stat"] = normalizedStat;
    }

    // V2Board 不一定提供 invite_url，需要从 panelUrl + 邀请码拼接
    if (!result.contains("invite_url") || result["invite_url"].toString().isEmpty()) {
        QJsonArray codes = result.value("codes").toArray();
        if (!codes.isEmpty()) {
            QString code = codes[0].toObject().value("code").toString();
            QString baseUrl = BundleConfig::instance().getValue("referUrl");
            if (baseUrl.isEmpty()) {
                baseUrl = BundleConfig::instance().panelUrl();
            }
            if (!baseUrl.isEmpty() && !code.isEmpty()) {
                if (baseUrl.endsWith("/")) baseUrl.chop(1);
                result["invite_url"] = baseUrl + "/#/register?code=" + code;
            }
        }
    }

    return result;
}

QJsonObject V2BoardNormalizer::normalizeUserStats(const QJsonObject& raw)
{
    QJsonObject result;

    // V2Board getStat 返回格式: {"data": [待处理订单数, 待处理工单数, 邀请用户数]}
    // 转换为统一对象格式
    QJsonValue dataValue = raw.value("data");
    if (dataValue.isArray()) {
        QJsonArray statsArray = dataValue.toArray();
        result["pending_orders"]  = statsArray.size() > 0 ? statsArray[0].toInt(0) : 0;
        result["pending_tickets"] = statsArray.size() > 1 ? statsArray[1].toInt(0) : 0;
        result["invited_count"]   = statsArray.size() > 2 ? statsArray[2].toInt(0) : 0;
    } else {
        // 已是对象格式，直接返回
        result = raw;
    }

    return result;
}
