use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Bookmark {
    pub id: String,
    pub original_url: String,
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub keyword: String,
    pub created_at: i64,
    pub modified_at: i64,
    #[serde(default)]
    pub usage_score: f64,
    #[serde(default)]
    pub last_opened_at: i64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookmarkInput {
    #[serde(default)]
    pub id: String,
    pub url: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub keyword: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UserSettings {
    pub default_search_scope: String,
    pub result_count: u8,
    pub open_in_new_window: bool,
    pub fetch_page_details: bool,
}

impl Default for UserSettings {
    fn default() -> Self {
        Self {
            default_search_scope: "all".into(),
            result_count: 5,
            open_in_new_window: false,
            fetch_page_details: false,
        }
    }
}
