/**
 * @file IPanelDataNormalizer.h
 * @brief 面板数据归一化接口定义
 * @details 定义面板返回数据的归一化接口，将不同面板的数据格式转换为统一格式。
 *          所有方法默认透传，子类只需覆盖有差异的方法。
 * @author JinGo VPN Team
 * @date 2025
 */

#ifndef IPANELDATANORMALIZER_H
#define IPANELDATANORMALIZER_H

#include <QJsonObject>
#include <QJsonArray>

/**
 * @class IPanelDataNormalizer
 * @brief 面板数据归一化接口
 *
 * @details
 * 不同面板（XBoard、V2Board、SSPanel 等）返回的数据格式可能不同，
 * 归一化器负责将这些差异统一为标准格式，使 ViewModel 层无需感知面板差异。
 *
 * 设计原则：
 * - 默认透传：所有方法的默认实现直接返回原始数据
 * - 按需覆盖：子类只覆盖有格式差异的方法
 * - 数据流位置：在 AuthManager/各 Manager 发信号之前调用
 *
 * 统一数据格式约定：
 * - stat 使用对象格式（含 registered_count, commission_rate 等命名字段）
 * - invite_url 保证存在（缺失时由 Normalizer 拼接）
 * - 时间戳统一为秒级 Unix 时间戳
 * - 流量统一为字节单位
 */
class IPanelDataNormalizer
{
public:
    virtual ~IPanelDataNormalizer() = default;

    // ========================================================================
    // 用户相关
    // ========================================================================

    /** @brief 归一化用户信息 */
    virtual QJsonObject normalizeUserInfo(const QJsonObject& raw) { return raw; }

    /** @brief 归一化订阅信息 */
    virtual QJsonObject normalizeSubscribeInfo(const QJsonObject& raw) { return raw; }

    // ========================================================================
    // 邀请相关
    // ========================================================================

    /** @brief 归一化邀请信息 */
    virtual QJsonObject normalizeInviteInfo(const QJsonObject& raw) { return raw; }

    // ========================================================================
    // 订单相关
    // ========================================================================

    /** @brief 归一化订单详情 */
    virtual QJsonObject normalizeOrderDetail(const QJsonObject& raw) { return raw; }

    /** @brief 归一化订单列表 */
    virtual QJsonArray normalizeOrders(const QJsonArray& raw) { return raw; }

    // ========================================================================
    // 套餐相关
    // ========================================================================

    /** @brief 归一化套餐列表 */
    virtual QJsonArray normalizePlans(const QJsonArray& raw) { return raw; }

    // ========================================================================
    // 支付相关
    // ========================================================================

    /** @brief 归一化支付方式列表 */
    virtual QJsonArray normalizePaymentMethods(const QJsonArray& raw) { return raw; }

    /** @brief 归一化支付/结账信息 */
    virtual QJsonObject normalizeCheckout(const QJsonObject& raw) { return raw; }

    // ========================================================================
    // 工单相关
    // ========================================================================

    /** @brief 归一化工单详情 */
    virtual QJsonObject normalizeTicketDetail(const QJsonObject& raw) { return raw; }

    /** @brief 归一化工单列表 */
    virtual QJsonArray normalizeTickets(const QJsonArray& raw) { return raw; }

    // ========================================================================
    // 系统相关
    // ========================================================================

    /** @brief 归一化系统配置 */
    virtual QJsonObject normalizeSystemConfig(const QJsonObject& raw) { return raw; }

    /** @brief 归一化公告列表 */
    virtual QJsonArray normalizeNotices(const QJsonArray& raw) { return raw; }

    /** @brief 归一化知识库文章列表 */
    virtual QJsonArray normalizeKnowledge(const QJsonArray& raw) { return raw; }

    // ========================================================================
    // 统计相关
    // ========================================================================

    /** @brief 归一化用户流量统计（如 V2Board 返回数组需转对象） */
    virtual QJsonObject normalizeUserStats(const QJsonObject& raw) { return raw; }
};

#endif // IPANELDATANORMALIZER_H
