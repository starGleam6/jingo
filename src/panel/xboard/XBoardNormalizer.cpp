/**
 * @file XBoardNormalizer.cpp
 * @brief XBoard 面板数据归一化器实现
 * @author JinGo VPN Team
 * @date 2025
 */

#include "XBoardNormalizer.h"
#include "core/BundleConfig.h"
#include <QJsonArray>
#include <QJsonValue>
QJsonObject XBoardNormalizer::normalizeInviteInfo(const QJsonObject& raw)
{
    QJsonObject result = raw;

    // XBoard 的 stat 是数组格式: [registered, valid_commission, pending_commission, rate, balance]
    // EzPanel 标准格式是对象: {registered_count, total_commission, commission_rate, commission_balance}
    QJsonValue statValue = raw.value("stat");
    if (statValue.isArray()) {
        QJsonArray stat = statValue.toArray();
        QJsonObject normalizedStat;
        normalizedStat["registered_count"]  = stat.size() > 0 ? stat[0].toInt(0) : 0;
        normalizedStat["total_commission"]  = stat.size() > 1 ? stat[1].toInt(0) : 0;
        normalizedStat["commission_rate"]   = stat.size() > 3 ? stat[3].toInt(0) : 0;
        normalizedStat["commission_balance"]= stat.size() > 4 ? stat[4].toInt(0) : 0;
        result["stat"] = normalizedStat;
    }

    // XBoard 不提供 invite_url，需要从 referUrl 或 panelUrl + 邀请码拼接
    if (!result.contains("invite_url") || result["invite_url"].toString().isEmpty()) {
        QJsonArray codes = result.value("codes").toArray();
        if (!codes.isEmpty()) {
            QString code = codes[0].toObject().value("code").toString();
            // 优先使用 referUrl，为空则 fallback 到 panelUrl
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

QJsonObject XBoardNormalizer::normalizeUserStats(const QJsonObject& raw)
{
    // XBoard getStat 返回格式与 V2Board 一致: {"data": [待处理订单数, 待处理工单数, 邀请用户数]}
    QJsonObject result;
    QJsonValue dataValue = raw.value("data");
    if (dataValue.isArray()) {
        QJsonArray statsArray = dataValue.toArray();
        result["pending_orders"]  = statsArray.size() > 0 ? statsArray[0].toInt(0) : 0;
        result["pending_tickets"] = statsArray.size() > 1 ? statsArray[1].toInt(0) : 0;
        result["invited_count"]   = statsArray.size() > 2 ? statsArray[2].toInt(0) : 0;
    } else {
        result = raw;
    }
    return result;
}
