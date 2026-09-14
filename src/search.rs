use crate::model::{Bookmark, DefaultResultOrder};

fn subsequence_score(haystack: &str, needle: &str) -> Option<i64> {
    let mut pos = 0usize;
    let mut gaps = 0i64;
    for ch in needle.chars() {
        let rest = haystack.get(pos..)?;
        let found = rest.find(ch)?;
        gaps += found as i64;
        pos += found + ch.len_utf8();
    }
    Some((120 - gaps).max(1))
}

fn field_score(field: &str, query: &str, weight: i64) -> i64 {
    let value = field.to_lowercase();
    if value == query {
        1_000 * weight
    } else if value.starts_with(query) {
        700 * weight
    } else if value
        .split(|c: char| !c.is_alphanumeric())
        .any(|w| w.starts_with(query))
    {
        560 * weight
    } else if value.contains(query) {
        350 * weight
    } else {
        subsequence_score(&value, query).unwrap_or(0) * weight
    }
}

pub fn rank(index: &[Bookmark], query: &str, limit: usize) -> Vec<Bookmark> {
    rank_in_order(index, query, limit, DefaultResultOrder::MostUsed)
}

pub fn rank_in_order(
    index: &[Bookmark],
    query: &str,
    limit: usize,
    order: DefaultResultOrder,
) -> Vec<Bookmark> {
    rank_with(
        index,
        query,
        limit,
        |item, q| {
            let title = field_score(&item.title, q, 8);
            let tags = item
                .tags
                .iter()
                .map(|tag| field_score(tag, q, 7))
                .max()
                .unwrap_or(0);
            let keyword = field_score(&item.keyword, q, 6);
            let url = field_score(&item.original_url, q, 4);
            let description = field_score(&item.description, q, 2);
            title.max(tags).max(keyword).max(url).max(description)
        },
        order,
    )
}

pub fn rank_tags(index: &[Bookmark], query: &str, limit: usize) -> Vec<Bookmark> {
    rank_tags_in_order(index, query, limit, DefaultResultOrder::MostUsed)
}

pub fn rank_tags_in_order(
    index: &[Bookmark],
    query: &str,
    limit: usize,
    order: DefaultResultOrder,
) -> Vec<Bookmark> {
    rank_with(
        index,
        query,
        limit,
        |item, q| {
            item.tags
                .iter()
                .map(|tag| field_score(tag, q, 7))
                .max()
                .unwrap_or(0)
        },
        order,
    )
}

fn rank_with(
    index: &[Bookmark],
    query: &str,
    limit: usize,
    score_item: impl Fn(&Bookmark, &str) -> i64,
    order: DefaultResultOrder,
) -> Vec<Bookmark> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        let mut defaults: Vec<&Bookmark> = index.iter().collect();
        defaults.sort_by(|a, b| {
            let primary = match order {
                DefaultResultOrder::MostUsed => b
                    .usage_score
                    .total_cmp(&a.usage_score)
                    .then_with(|| b.last_opened_at.cmp(&a.last_opened_at)),
                DefaultResultOrder::RecentlyUsed => b
                    .last_opened_at
                    .cmp(&a.last_opened_at)
                    .then_with(|| b.usage_score.total_cmp(&a.usage_score)),
            };
            primary
                .then_with(|| b.created_at.cmp(&a.created_at))
                .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
                .then_with(|| a.id.cmp(&b.id))
        });
        return defaults.into_iter().take(limit).cloned().collect();
    }
    let mut scored: Vec<(i64, &Bookmark)> = index
        .iter()
        .filter_map(|item| {
            let score = score_item(item, &q);
            (score > 0).then_some((score, item))
        })
        .collect();
    scored.sort_by(|(ascore, a), (bscore, b)| {
        bscore
            .cmp(ascore)
            .then_with(|| b.usage_score.total_cmp(&a.usage_score))
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
            .then_with(|| a.id.cmp(&b.id))
    });
    scored
        .into_iter()
        .take(limit)
        .map(|(_, item)| item.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    fn b(id: &str, title: &str) -> Bookmark {
        Bookmark {
            id: id.into(),
            original_url: format!("https://{id}.test"),
            title: title.into(),
            description: String::new(),
            tags: vec![],
            keyword: String::new(),
            created_at: 0,
            modified_at: 0,
            usage_score: 0.0,
            last_opened_at: 0,
        }
    }
    #[test]
    fn empty_returns_most_used_then_most_recent() {
        let mut unused_old = b("unused-old", "Unused old");
        unused_old.created_at = 10;
        let mut unused_new = b("unused-new", "Unused new");
        unused_new.created_at = 20;
        let mut used_old = b("used-old", "Used old");
        used_old.usage_score = 2.0;
        used_old.last_opened_at = 30;
        let mut used_new = b("used-new", "Used new");
        used_new.usage_score = 2.0;
        used_new.last_opened_at = 40;
        let mut favorite = b("favorite", "Favorite");
        favorite.usage_score = 3.0;

        let got = rank(
            &[unused_old, used_old, unused_new, favorite, used_new],
            "   ",
            5,
        );
        assert_eq!(
            got.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(),
            vec![
                "favorite",
                "used-new",
                "used-old",
                "unused-new",
                "unused-old"
            ]
        );
    }
    #[test]
    fn empty_honors_a_ten_result_limit() {
        let bookmarks: Vec<_> = (0..12)
            .map(|index| b(&format!("item-{index}"), &format!("Item {index}")))
            .collect();
        assert_eq!(rank(&bookmarks, "", 10).len(), 10);
    }
    #[test]
    fn empty_can_return_most_recently_used() {
        let mut frequent = b("frequent", "Frequent");
        frequent.usage_score = 10.0;
        frequent.last_opened_at = 20;
        let mut recent = b("recent", "Recent");
        recent.usage_score = 1.0;
        recent.last_opened_at = 30;
        let mut never_opened = b("never-opened", "Never opened");
        never_opened.created_at = 40;

        let got = rank_in_order(
            &[frequent, recent, never_opened],
            "",
            3,
            DefaultResultOrder::RecentlyUsed,
        );
        assert_eq!(
            got.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(),
            vec!["recent", "frequent", "never-opened"]
        );
    }
    #[test]
    fn exact_then_prefix_then_substring() {
        let got = rank(
            &[
                b("c", "An Alpha Thing"),
                b("b", "Alphabet"),
                b("a", "Alpha"),
            ],
            "alpha",
            8,
        );
        assert_eq!(
            got.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(),
            vec!["a", "b", "c"]
        );
    }
    #[test]
    fn ties_are_deterministic() {
        let got = rank(&[b("b", "Same"), b("a", "Same")], "same", 8);
        assert_eq!(got[0].id, "a");
    }
    #[test]
    fn tag_search_only_matches_tags() {
        let mut title_match = b("title", "Rust handbook");
        title_match.tags = vec!["docs".into()];
        let mut tag_match = b("tag", "Handbook");
        tag_match.tags = vec!["rust".into()];
        let got = rank_tags(&[title_match, tag_match], "rust", 5);
        assert_eq!(
            got.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(),
            vec!["tag"]
        );
    }
}
