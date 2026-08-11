#pragma once

#include <QAbstractListModel>
#include <QJsonArray>

//! 单个媒体条目(Emby Items JSON 解析结果)。
struct MediaItem {
    QString name;
    QString id;
    QString posterId;
    QString type;
};

//! Emby 视图/媒体库条目列表模型,由 EmbyClient 填充。
//! 角色:name(名称)、id(条目 id)、posterId("<itemId>~<tag>",无主图则为空)、
//! type(条目类型,如 "Movie")。
class MediaItemModel : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    //! 服务器端条目总数(Items 查询的 TotalRecordCount),用于分页判断。
    Q_PROPERTY(int totalCount READ totalCount NOTIFY totalCountChanged)
public:
    enum Roles {
        NameRole = Qt::UserRole + 1,
        IdRole,
        PosterIdRole,
        TypeRole,
    };

    explicit MediaItemModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const { return m_items.size(); }
    int totalCount() const { return m_total; }

    // 用 Emby Items JSON 数组重建模型;withPosters 为真时解析 ImageTags.Primary 拼 posterId。
    Q_INVOKABLE void setItems(const QJsonArray &items, bool withPosters);
    // 追加一页条目(分页加载用)。
    Q_INVOKABLE void appendItems(const QJsonArray &items, bool withPosters);
    // 设置服务器端总数。
    Q_INVOKABLE void setTotal(int total);
    // 清空全部条目。
    Q_INVOKABLE void clear();
    // 取第 row 条的 id,越界返回空串。
    Q_INVOKABLE QString idAt(int row) const;
    // 取第 row 条的名称,越界返回空串。
    Q_INVOKABLE QString nameAt(int row) const;
    // 取第 row 条的海报 id(<itemId>~<tag>),越界返回空串。
    Q_INVOKABLE QString posterIdAt(int row) const;

signals:
    void countChanged();
    void totalCountChanged();

private:
    QList<MediaItem> m_items;
    int m_total = 0;
};
