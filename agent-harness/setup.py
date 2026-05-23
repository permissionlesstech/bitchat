from setuptools import find_namespace_packages, setup


setup(
    name="cli-anything-bitchat",
    version="0.1.0",
    description="CLI-Anything harness for BitChat",
    packages=find_namespace_packages(include=["cli_anything.*"]),
    install_requires=["click>=8.0"],
    entry_points={
        "console_scripts": [
            "cli-anything-bitchat=cli_anything.bitchat.bitchat_cli:main",
        ],
    },
    python_requires=">=3.9",
)
