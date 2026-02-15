from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str = "postgresql+asyncpg://hub:hub_dev_password@localhost:5432/hub"
    redis_url: str = "redis://localhost:6379/0"
    environment: str = "development"
    openai_api_key: str = ""
    anthropic_api_key: str = ""
    gemini_api_key: str = ""

    model_config = {"env_file": ".env"}


settings = Settings()
